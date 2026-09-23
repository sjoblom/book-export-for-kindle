import fs from 'node:fs/promises'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import vm from 'node:vm'

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { UserConfig } from './config'
import type * as ExtractKindleBook from './extract-kindle-book'
import type * as KindleLibrary from './kindle-library'
import type { LibraryBook } from './kindle-library'
import type * as Pipeline from './pipeline'
import { renderPage } from './serve-page'

// The server reads and writes the stored config; the real one lives in the
// home directory of whoever runs the tests.
let stored: UserConfig = {}
vi.mock('./config', () => ({
  loadConfig: async () => stored,
  saveConfig: async (config: UserConfig) => {
    stored = config
    return '/dev/null'
  }
}))

/**
 * Jobs are driven through a stand-in pipeline: the real one opens Chrome and
 * reads a book for an hour. Everything around it — validation, the queue, the
 * options each book is started with — is the server's own code.
 */
const pipelineCalls = vi.hoisted(() => [] as Array<Record<string, unknown>>)
const gate = vi.hoisted(() => ({
  hold: false,
  release: undefined as (() => void) | undefined
}))

vi.mock('./pipeline', async (importOriginal) => {
  const actual = await importOriginal<typeof Pipeline>()

  return {
    ...actual,
    processBook: async (asin: string, options: any) => {
      pipelineCalls.push({
        asin,
        command: options.command,
        forceCapture: options.forceCapture,
        formats: options.formats,
        model: options.model
      })

      if (gate.hold) {
        await new Promise<void>((resolve) => {
          gate.release = () => {
            gate.release = undefined
            resolve()
          }
        })
      }

      return {
        asin,
        outputs: [],
        completeness: {
          complete: true,
          capturedPages: 1,
          transcribedPages: 1,
          missingPages: [],
          captureStoppedEarly: false,
          warnings: []
        },
        failedPages: [],
        durationMs: 1
      }
    }
  }
})

/**
 * Chrome, Amazon and the sign-in window, stood in for. The server starts a
 * library refresh the moment it is created, so every test runs against these;
 * each test can say what the next library read finds.
 */
type LibraryOutcome = LibraryBook[] | 'signed-out'
const browser = vi.hoisted(() => ({
  launches: 0,
  libraryReads: 0,
  logins: 0,
  loginConfirms: true,
  profileBusy: false,
  /** Outcomes for the next library reads, in order; then `fallback`. */
  outcomes: [] as unknown[],
  fallback: undefined as unknown,
  holdLibrary: false,
  releaseLibrary: undefined as (() => void) | undefined
}))

vi.mock('./extract-kindle-book', async (importOriginal) => {
  const actual = await importOriginal<typeof ExtractKindleBook>()
  const page = {}
  const context = {
    pages: () => [page],
    newPage: async () => page,
    close: async () => {},
    browser: () => null
  }

  return {
    ...actual,
    launchBrowserContext: async () => {
      browser.launches++
      if (browser.profileBusy) {
        throw Object.assign(new Error('profile busy'), { code: 'PROFILE_BUSY' })
      }
      return context
    },
    hideBrowserWindow: async () => {}
  }
})

vi.mock('./kindle-library', async (importOriginal) => {
  const actual = await importOriginal<typeof KindleLibrary>()

  return {
    ...actual,
    fetchLibrary: async () => {
      browser.libraryReads++
      if (browser.holdLibrary) {
        await new Promise<void>((resolve) => {
          browser.releaseLibrary = () => {
            browser.releaseLibrary = undefined
            resolve()
          }
        })
      }

      const outcome = (
        browser.outcomes.length ? browser.outcomes.shift() : browser.fallback
      ) as LibraryOutcome
      if (outcome === 'signed-out') throw new actual.NotSignedInError()
      return outcome
    }
  }
})

vi.mock('./session', () => ({
  interactiveLogin: async () => {
    browser.logins++
    return browser.loginConfirms
  }
}))

/** Spelled in two halves so the linter doesn't take the test data for code. */
const SCRIPT_URL = ['javascript', 'alert(1)'].join(':')

const LIBRARY: LibraryBook[] = [
  {
    asin: 'B00TEST',
    title: 'The Test Book',
    authors: ['Ann Author'],
    coverUrl: 'https://m.media-amazon.com/images/I/test.jpg'
  },
  { asin: 'B00OTHER', title: 'Another Book', authors: [] }
]

const { createServeHandle } = await import('./serve')
const { EMPTY_OPTIONS } = await import('./pipeline')
const { isVisionOcrAvailable } = await import('./vision-ocr')

/** Whether this machine can read pages itself; decides which gate applies. */
const localOcr = await isVisionOcrAvailable()

type Handle = Awaited<ReturnType<typeof createServeHandle>>

let outDir: string
let handle: Handle
let port: number

function serveOptions(extra: Partial<Pipeline.Options> = {}) {
  return {
    ...EMPTY_OPTIONS,
    command: 'serve',
    outDir,
    profileDir: path.join(outDir, '.profile'),
    port: 0,
    ...extra
  }
}

beforeEach(async () => {
  stored = {}
  pipelineCalls.length = 0
  gate.hold = false
  gate.release = undefined
  Object.assign(browser, {
    launches: 0,
    libraryReads: 0,
    logins: 0,
    loginConfirms: true,
    profileBusy: false,
    outcomes: [],
    fallback: LIBRARY,
    holdLibrary: false,
    releaseLibrary: undefined
  })
  vi.stubEnv('OPENAI_API_KEY', '')

  outDir = await fs.mkdtemp(path.join(os.tmpdir(), 'kindle-export-serve-'))
  const bookDir = path.join(outDir, 'B00TEST')
  await fs.mkdir(bookDir, { recursive: true })
  await fs.writeFile(path.join(bookDir, 'the-book.md'), 'hello book')
  await fs.writeFile(path.join(bookDir, 'notes.txt'), 'not downloadable')
  // A file outside the book folder that a traversal would reach.
  await fs.writeFile(path.join(outDir, 'secret.md'), 'should stay put')

  handle = await createServeHandle(serveOptions())
  port = Number(new URL(handle.url).port)
})

afterEach(async () => {
  gate.hold = false
  gate.release?.()
  browser.holdLibrary = false
  browser.releaseLibrary?.()
  await handle.close()
  await fs.rm(outDir, { recursive: true, force: true })
  vi.unstubAllEnvs()
})

function post(
  pathname: string,
  body?: unknown,
  headers?: Record<string, string>,
  base = handle.url
) {
  return fetch(base + pathname, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-kindle-export': '1',
      ...headers
    },
    body: JSON.stringify(body ?? {})
  })
}

/** Wait for something the job runs towards, rather than for a fixed delay. */
async function until(
  condition: () => boolean | Promise<boolean>,
  what: string,
  timeoutMs = 5000
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

async function getState(base = handle.url): Promise<any> {
  return (await fetch(base + '/api/state')).json()
}

/** Wait until nothing holds the browser: no refresh, sign-in or export. */
async function idle(base = handle.url): Promise<any> {
  let state: any
  await until(async () => {
    state = await getState(base)
    return state.busy === null
  }, 'the browser to be free')
  return state
}

/** The queue entries, reduced to what the tests compare. */
async function queued(base = handle.url): Promise<string[]> {
  const state = await getState(base)
  return state.queue.books.map((b: any) => `${b.asin}:${b.status}`)
}

/** A request with full header control, for what fetch won't let us send. */
function rawGet(
  pathname: string,
  headers: Record<string, string>
): Promise<{ status: number }> {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port, path: pathname, headers },
      (res) => {
        res.resume()
        res.on('end', () => resolve({ status: res.statusCode ?? 0 }))
      }
    )
    req.on('error', reject)
    req.end()
  })
}

describe('serve', () => {
  it('serves the app page', async () => {
    const res = await fetch(handle.url + '/')
    expect(res.status).toBe(200)
    expect(await res.text()).toContain('Kindle Export')
  })

  it('reports state, including books found on disk', async () => {
    const state = await idle()

    expect(state.hasApiKey).toBe(false)
    expect(state.alsoPdf).toBe(false)
    expect(state.profileBusy).toBe(false)
    expect(state.queue).toEqual({ books: [], stopRequested: false, log: [] })
    expect(state.diskBooks).toHaveLength(1)
    expect(state.diskBooks[0]).toMatchObject({ asin: 'B00TEST' })
    expect(state.diskBooks[0].exports.map((f: any) => f.name)).toEqual([
      'the-book.md'
    ])
    expect(state).not.toHaveProperty('job')
  })

  it('page script parses', async () => {
    // The script is a string inside a TypeScript template literal, where a
    // stray backtick or backslash breaks it without any compiler noticing.
    const html = await (await fetch(handle.url + '/')).text()
    const script = /<script>([\s\S]*)<\/script>/.exec(html)?.[1]
    expect(script).toBeTruthy()
    // Compiled, not run: a syntax error throws here.
    expect(() => new vm.Script(script!)).not.toThrow()
    // Every write the page makes has to carry the app header.
    expect(script).toContain("'x-kindle-export': '1'")
  })

  it('rejects requests with a foreign Host header (DNS rebinding)', async () => {
    const { status } = await rawGet('/api/state', { host: 'evil.example' })
    expect(status).toBe(403)
  })

  it('rejects writes without the app header (cross-site requests)', async () => {
    for (const pathname of ['/api/library', '/api/export', '/api/queue/stop']) {
      const res = await fetch(handle.url + pathname, { method: 'POST' })
      expect(res.status).toBe(403)
    }
  })

  it('reports whether pages can be read on this machine', async () => {
    const state = await getState()
    // Drives the whole key form: with local OCR there is nothing to fill in,
    // so it must reflect reality rather than a guess about the platform.
    expect(state.localOcr).toBe(localOcr)
  })

  it('refuses to export without an API key when started with a model', async () => {
    // Naming a model means OpenAI reads the pages, so a key is required even
    // where local OCR would otherwise have covered it.
    const withModel = await createServeHandle(
      serveOptions({ model: 'gpt-test' })
    )

    try {
      const state = await idle(withModel.url)
      expect(state.needsApiKey).toBe(true)

      const res = await post(
        '/api/export',
        { asin: 'B00TEST' },
        {},
        withModel.url
      )
      expect(res.status).toBe(400)
      expect(((await res.json()) as any).error).toMatch(/API key/)

      // With a key, the book is read with the model `serve` was given.
      vi.stubEnv('OPENAI_API_KEY', 'sk-test')
      const started = await post(
        '/api/export',
        { asin: 'B00TEST' },
        {},
        withModel.url
      )
      expect(started.status).toBe(202)
      await until(() => pipelineCalls.length === 1, 'the book to be processed')
      expect(pipelineCalls[0]!.model).toBe('gpt-test')
      await idle(withModel.url)
    } finally {
      await withModel.close()
    }
  })

  it('needs a key exactly when this machine cannot read pages', async () => {
    const state = await getState()
    expect(state.needsApiKey).toBe(!localOcr)
    // Choosing a model is not something the page can do, so it isn't told
    // about one either.
    expect(state).not.toHaveProperty('model')
    expect(state).not.toHaveProperty('defaultModel')
  })

  it.skipIf(localOcr)(
    'refuses to export without an API key when there is no local OCR',
    async () => {
      const res = await post('/api/export', { asin: 'B00TEST' })
      expect(res.status).toBe(400)
      expect(((await res.json()) as any).error).toMatch(/API key/)
    }
  )

  it('validates the export request before touching a browser', async () => {
    vi.stubEnv('OPENAI_API_KEY', 'sk-test')
    await idle()

    for (const body of [
      {},
      { asin: '' },
      { asin: 'b00!bad' },
      { asin: '../escape' },
      { asin: ['B00TEST'] },
      { asins: ['B00TEST'] },
      { asin: 'A'.repeat(21) },
      { asin: 'B00TEST', formats: 'pdf' },
      { asin: 'B00TEST', formats: ['docx'] }
    ]) {
      const res = await post('/api/export', body)
      expect(res.status, JSON.stringify(body)).toBe(400)
    }

    expect(pipelineCalls).toHaveLength(0)
    expect((await getState()).queue.books).toEqual([])
  })

  it('saves settings and makes the key usable without a restart', async () => {
    const res = await post('/api/config', { apiKey: 'sk-new' })
    expect(res.status).toBe(200)

    expect(stored).toEqual({ openaiApiKey: 'sk-new' })
    expect((await getState()).hasApiKey).toBe(true)
  })

  it('ignores a model sent to the settings endpoint', async () => {
    // An older page, or anything else posting here, must not be able to
    // switch reading to a paid API — that is a command-line decision.
    const res = await post('/api/config', { apiKey: 'sk-new', model: 'gpt-x' })
    expect(res.status).toBe(200)

    expect(stored).toEqual({ openaiApiKey: 'sk-new' })
    const state = await getState()
    expect(state.needsApiKey).toBe(!localOcr)
    expect(state).not.toHaveProperty('model')
  })

  it('keeps a stored key when settings are saved without one', async () => {
    stored = { openaiApiKey: 'sk-old', outDir: 'books' }

    const res = await post('/api/config', {})
    expect(res.status).toBe(200)
    expect(stored).toEqual({ openaiApiKey: 'sk-old', outDir: 'books' })
  })

  it('makes a PDF as well once the setting is on', async () => {
    vi.stubEnv('OPENAI_API_KEY', 'sk-test')

    const res = await post('/api/config', { alsoPdf: true })
    expect(res.status).toBe(200)
    expect(stored).toEqual({ alsoPdf: true })
    expect((await getState()).alsoPdf).toBe(true)

    expect((await post('/api/export', { asin: 'B00TEST' })).status).toBe(202)
    await until(() => pipelineCalls.length === 1, 'the book to be processed')
    expect(pipelineCalls[0]!.formats).toEqual(['md', 'pdf'])
  })

  it('downloads an exported file', async () => {
    const res = await fetch(handle.url + '/api/download/B00TEST/the-book.md')
    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toContain('text/markdown')
    expect(res.headers.get('content-disposition')).toContain('attachment')
    expect(await res.text()).toBe('hello book')
  })

  it('downloads a file whose name is not Latin-1', async () => {
    // Someone renames an export by hand and it still has to come down. The raw
    // name in a header is what Node refuses outright, so the plain `filename`
    // has to be an ASCII stand-in with the real name only in `filename*`.
    const name = '日本語.md'
    await fs.writeFile(path.join(outDir, 'B00TEST', name), 'hello book')

    const res = await fetch(
      handle.url + '/api/download/B00TEST/' + encodeURIComponent(name)
    )
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('hello book')

    const disposition = res.headers.get('content-disposition') ?? ''
    expect(disposition).toBe(
      `attachment; filename="book.md"; filename*=UTF-8''${encodeURIComponent(name)}`
    )
    // Latin-1 only, or Node would never have written it in the first place.
    expect(disposition).toMatch(/^[ -~]+$/)
  })

  it('refuses download paths that leave the book folder', async () => {
    const traversal = await fetch(
      handle.url + '/api/download/B00TEST/..%2Fsecret.md'
    )
    expect(traversal.status).toBe(400)

    const wrongType = await fetch(
      handle.url + '/api/download/B00TEST/notes.txt'
    )
    expect(wrongType.status).toBe(400)

    const badAsin = await fetch(handle.url + '/api/download/b00%2F../x.md')
    expect(badAsin.status).toBe(400)

    const absent = await fetch(handle.url + '/api/download/B00TEST/absent.md')
    expect(absent.status).toBe(404)
  })

  it('captures a book again when the page asks it to', async () => {
    // The only way out of a capture that stopped part-way: without this the
    // same truncated book is rebuilt from the same pages every time.
    vi.stubEnv('OPENAI_API_KEY', 'sk-test')
    gate.hold = true

    const res = await post('/api/export', {
      asin: 'B00TEST',
      forceCapture: true
    })
    expect(res.status).toBe(202)

    await until(() => pipelineCalls.length === 1, 'the book to be processed')
    expect(pipelineCalls[0]).toMatchObject({
      asin: 'B00TEST',
      command: 'all',
      forceCapture: true
    })

    // The page needs to know a run is a re-capture, not an ordinary export.
    const [book] = (await getState()).queue.books
    expect(book).toMatchObject({ asin: 'B00TEST', forceCapture: true })
  })

  it('resumes rather than re-captures for an ordinary export', async () => {
    // Retrying unreadable pages must not throw away an hour of capture; the
    // pipeline resumes page by page when it is left alone.
    vi.stubEnv('OPENAI_API_KEY', 'sk-test')

    expect((await post('/api/export', { asin: 'B00TEST' })).status).toBe(202)

    await until(() => pipelineCalls.length === 1, 'the book to be processed')
    expect(pipelineCalls[0]).toMatchObject({
      forceCapture: false,
      formats: ['md']
    })

    const state = await idle()
    expect(state.queue.books).toMatchObject([
      { asin: 'B00TEST', title: 'The Test Book', status: 'done' }
    ])
  })

  it('reads pages without a model stored by an older setup', async () => {
    // Older setups prefilled gpt-4.1-mini, so a job that honoured it would
    // silently send every page to a paid API instead of reading it locally.
    vi.stubEnv('OPENAI_API_KEY', 'sk-test')
    stored = { model: 'gpt-4.1-mini' } as UserConfig

    expect((await post('/api/export', { asin: 'B00TEST' })).status).toBe(202)

    await until(() => pipelineCalls.length === 1, 'the book to be processed')
    expect(pipelineCalls[0]!.model).toBeUndefined()
  })

  it('stays quiet about unknown routes', async () => {
    const res = await fetch(handle.url + '/api/nope')
    expect(res.status).toBe(404)
  })
})

function pageScript(html: string): string {
  const script = /<script>([\s\S]*)<\/script>/.exec(html)?.[1]
  expect(script).toBeTruthy()
  return script!
}

/**
 * Just enough DOM for the page script to load and run its first calls: every
 * element is the same do-nothing object, so what the test sees is only what
 * crosses the bridge.
 */
function fakeBrowser() {
  const element: any = new Proxy(function () {}, {
    get: (_target, key) => {
      if (key === Symbol.toPrimitive) return () => ''
      if (key === 'children') return []
      if (key === 'hidden') return true
      if (key === 'value' || key === 'textContent') return ''
      return element
    },
    set: () => true,
    apply: () => element
  })
  const messages: any[] = []
  const window: any = {
    webkit: {
      messageHandlers: { kindle: { postMessage: (m: any) => messages.push(m) } }
    }
  }
  const context = vm.createContext({
    window,
    document: element,
    setTimeout,
    clearTimeout,
    setInterval: () => 0,
    Promise
  })
  return { context, window, messages }
}

describe('page transport', () => {
  // These tests need no server, but the file-wide hooks start one; let its
  // start-up library read finish before the teardown removes its folder.
  beforeEach(async () => {
    await idle()
  })

  it('http mode is the default and parses', () => {
    expect(renderPage()).toBe(renderPage({ transport: 'http' }))
    const script = pageScript(renderPage())
    expect(() => new vm.Script(script)).not.toThrow()
    expect(script).toContain("new EventSource('/api/events')")
    expect(script).toContain("'x-kindle-export': '1'")
    expect(script).not.toContain('messageHandlers')
  })

  it('bridge mode parses and never touches HTTP', () => {
    const html = renderPage({ transport: 'bridge' })
    const script = pageScript(html)
    expect(() => new vm.Script(script)).not.toThrow()
    expect(script).not.toContain('EventSource')
    expect(script).not.toMatch(/\bfetch\(/)
    expect(script).toContain('window.webkit.messageHandlers.kindle')
    // Loaded from a file, the page has no server: any relative URL in an
    // attribute (src, href, action) would resolve to nothing.
    const urls = [
      ...html.matchAll(/(?<![\w-])(?:src|href|action)=["']([^"']*)/g)
    ].map((m) => m[1])
    for (const url of urls) expect(url).toMatch(/^(data:|https:)/)
  })

  it('names the window Amazon actually runs in', () => {
    // The app has no Chrome: telling someone to sign in "in the Chrome
    // window" sends them looking for a window that doesn't exist.
    const bridge = pageScript(renderPage({ transport: 'bridge' }))
    expect(bridge).toContain("window: 'the Amazon window'")
    expect(bridge).not.toMatch(/Chrome window|A Chrome window/)

    const http = pageScript(renderPage())
    expect(http).toContain("window: 'the Chrome window'")
  })

  it('bridge mode sends requests and settles them from replies', async () => {
    const { context, window, messages } = fakeBrowser()
    new vm.Script(pageScript(renderPage({ transport: 'bridge' }))).runInContext(
      context
    )

    // The page asks for the state (with a disk scan) as soon as it loads.
    expect(messages).toEqual([
      { id: '1', method: 'GET', path: '/api/state?scan=1' }
    ])
    expect(typeof window.__kindleState).toBe('function')

    const reply = vm.runInContext(
      "request('POST', '/api/export', { asin: 'B00TEST' })",
      context
    )
    expect(messages[1]).toEqual({
      id: '2',
      method: 'POST',
      path: '/api/export',
      body: { asin: 'B00TEST' }
    })
    window.__kindleReply('2', 200, '{"ok":true}')
    await expect(reply).resolves.toEqual({ ok: true })

    const failed = vm.runInContext(
      "request('POST', '/api/queue/stop')",
      context
    )
    window.__kindleReply(messages[2].id, 409, { error: 'Nothing to stop.' })
    await expect(failed).rejects.toThrow('Nothing to stop.')
  })

  it('bridge mode gives up on a request the app never answers', async () => {
    vi.useFakeTimers()
    try {
      const { context } = fakeBrowser()
      context.setTimeout = setTimeout
      context.clearTimeout = clearTimeout
      new vm.Script(
        pageScript(renderPage({ transport: 'bridge' }))
      ).runInContext(context)
      const reply = vm.runInContext("request('POST', '/api/library')", context)
      const settled = expect(reply).rejects.toThrow('did not answer')
      await vi.advanceTimersByTimeAsync(30_000)
      await settled
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('serve queue', () => {
  beforeEach(async () => {
    vi.stubEnv('OPENAI_API_KEY', 'sk-test')
    await idle()
    gate.hold = true
  })

  it('queues books clicked while one is exporting, and runs them in order', async () => {
    expect((await post('/api/export', { asin: 'B00TEST' })).status).toBe(202)
    await until(() => pipelineCalls.length === 1, 'the first book to start')

    // One browser profile, one book at a time: the second click waits.
    expect((await post('/api/export', { asin: 'B00OTHER' })).status).toBe(202)
    expect(await queued()).toEqual(['B00TEST:working', 'B00OTHER:queued'])
    expect((await getState()).busy).toBe('export')
    expect(pipelineCalls).toHaveLength(1)

    gate.release?.()
    await until(() => pipelineCalls.length === 2, 'the second book to start')
    expect(pipelineCalls.map((call) => call.asin)).toEqual([
      'B00TEST',
      'B00OTHER'
    ])

    gate.release?.()
    await idle()
    expect(await queued()).toEqual(['B00TEST:done', 'B00OTHER:done'])
  })

  it('does not queue a book twice', async () => {
    await post('/api/export', { asin: 'B00TEST' })
    await until(() => pipelineCalls.length === 1, 'the first book to start')
    await post('/api/export', { asin: 'B00OTHER' })

    // A double click, or a click on a book already being exported, is the
    // same request again.
    for (const asin of ['B00OTHER', 'B00TEST']) {
      expect((await post('/api/export', { asin })).status).toBe(202)
    }
    expect(await queued()).toEqual(['B00TEST:working', 'B00OTHER:queued'])
  })

  it('exports a finished book again when asked, replacing its outcome', async () => {
    gate.hold = false
    await post('/api/export', { asin: 'B00TEST' })
    await until(() => pipelineCalls.length === 1, 'the first export')
    await idle()

    await post('/api/export', { asin: 'B00TEST' })
    await until(() => pipelineCalls.length === 2, 'the second export')
    await idle()
    expect(await queued()).toEqual(['B00TEST:done'])
  })

  it('removes a waiting book, but not the one being exported', async () => {
    await post('/api/export', { asin: 'B00TEST' })
    await until(() => pipelineCalls.length === 1, 'the first book to start')
    await post('/api/export', { asin: 'B00OTHER' })

    expect((await post('/api/queue/remove', { asin: 'B00OTHER' })).status).toBe(
      200
    )
    expect(await queued()).toEqual(['B00TEST:working'])

    expect((await post('/api/queue/remove', { asin: 'B00TEST' })).status).toBe(
      409
    )
    expect((await post('/api/queue/remove', { asin: 'B00NONE' })).status).toBe(
      404
    )
    expect((await post('/api/queue/remove', { asin: '../x' })).status).toBe(400)

    gate.release?.()
    await idle()
    expect(pipelineCalls.map((call) => call.asin)).toEqual(['B00TEST'])
  })

  it('stops after the current book, and runs books clicked after that', async () => {
    await post('/api/export', { asin: 'B00TEST' })
    await until(() => pipelineCalls.length === 1, 'the first book to start')
    await post('/api/export', { asin: 'B00OTHER' })
    await post('/api/export', { asin: 'B00THIRD' })

    // Everything waiting comes off the queue; the current book finishes, as
    // cutting a capture short would only leave a truncated book.
    expect((await post('/api/queue/stop')).status).toBe(200)
    let state = await getState()
    expect(state.queue.stopRequested).toBe(true)
    expect(await queued()).toEqual(['B00TEST:working'])

    // A book clicked after Stop is a new request, not one Stop cancelled.
    await post('/api/export', { asin: 'B00FOURTH' })
    state = await getState()
    expect(state.queue.stopRequested).toBe(false)

    gate.release?.()
    await until(() => pipelineCalls.length === 2, 'the next book to start')
    gate.release?.()
    await idle()
    expect(pipelineCalls.map((call) => call.asin)).toEqual([
      'B00TEST',
      'B00FOURTH'
    ])
  })

  it('caps how many books can wait at once', async () => {
    await post('/api/export', { asin: 'B00TEST' })
    await until(() => pipelineCalls.length === 1, 'the first book to start')

    for (let i = 1; i < 50; i++) {
      const res = await post('/api/export', {
        asin: `B${String(i).padStart(9, '0')}`
      })
      expect(res.status).toBe(202)
    }
    const over = await post('/api/export', { asin: 'B999999999' })
    expect(over.status).toBe(400)
    expect((await getState()).queue.books).toHaveLength(50)
  })

  it('refuses to refresh the library while exporting', async () => {
    // The export holds the browser profile; a refresh would have to open it
    // a second time.
    await post('/api/export', { asin: 'B00TEST' })
    await until(() => pipelineCalls.length === 1, 'the book to start')

    const reads = browser.libraryReads
    expect((await post('/api/library')).status).toBe(409)
    expect(browser.libraryReads).toBe(reads)
  })
})

describe('serve start-up', () => {
  it('reads the library in the background as soon as it starts', async () => {
    const state = await idle()

    expect(browser.libraryReads).toBe(1)
    expect(state.amazon).toBe('signed-in')
    expect(state.library.fromCache).toBe(false)
    expect(state.library.books.map((b: any) => b.asin)).toEqual([
      'B00TEST',
      'B00OTHER'
    ])
    expect(state.library.books[0].coverUrl).toBe(LIBRARY[0]!.coverUrl)

    // ... and keeps it for the next launch.
    const cache: any = JSON.parse(
      await fs.readFile(
        path.join(outDir, '.profile', 'kindle-export-library.json'),
        'utf8'
      )
    )
    expect(cache.books.map((b: any) => b.asin)).toEqual(['B00TEST', 'B00OTHER'])
    expect(typeof cache.fetchedAt).toBe('number')
  })

  it('shows the cached library straight away while it refreshes', async () => {
    await idle()
    await fs.writeFile(
      path.join(outDir, '.profile', 'kindle-export-library.json'),
      JSON.stringify({
        version: 1,
        fetchedAt: 1234,
        books: [
          {
            asin: 'B00CACHED',
            title: 'From Last Time',
            authors: ['Someone'],
            coverUrl: 'https://m.media-amazon.com/images/I/c.jpg'
          },
          // Read back from disk, so checked like the live payload is.
          {
            asin: 'B00EVIL',
            title: 'Bad Cover',
            authors: [],
            coverUrl: SCRIPT_URL
          },
          { asin: '../nope', title: 'Bad ASIN', authors: [] }
        ]
      })
    )

    browser.holdLibrary = true
    const second = await createServeHandle(serveOptions())
    try {
      const state = await getState(second.url)
      expect(state.busy).toBe('library')
      expect(state.library).toMatchObject({ fetchedAt: 1234, fromCache: true })
      expect(state.library.books).toEqual([
        {
          asin: 'B00CACHED',
          title: 'From Last Time',
          authors: ['Someone'],
          coverUrl: 'https://m.media-amazon.com/images/I/c.jpg'
        },
        { asin: 'B00EVIL', title: 'Bad Cover', authors: [] }
      ])

      await until(() => !!browser.releaseLibrary, 'the refresh to start')
      browser.releaseLibrary!()
      const refreshed = await idle(second.url)
      expect(refreshed.library.fromCache).toBe(false)
      expect(refreshed.library.books.map((b: any) => b.asin)).toEqual([
        'B00TEST',
        'B00OTHER'
      ])
    } finally {
      browser.holdLibrary = false
      browser.releaseLibrary?.()
      await second.close()
    }
  })

  it('opens the sign-in window once when nobody is signed in, then reads the library', async () => {
    await idle()
    browser.outcomes = ['signed-out', LIBRARY]
    browser.loginConfirms = true

    const second = await createServeHandle(serveOptions())
    try {
      const state = await idle(second.url)
      expect(browser.logins).toBe(1)
      expect(state.amazon).toBe('signed-in')
      expect(state.library.books).toHaveLength(2)
    } finally {
      await second.close()
    }
  })

  it('does not open the sign-in window by itself a second time', async () => {
    await idle()
    browser.fallback = 'signed-out'
    browser.loginConfirms = false // the person closed the window

    const second = await createServeHandle(serveOptions())
    try {
      let state = await idle(second.url)
      expect(browser.logins).toBe(1)
      expect(state.amazon).toBe('signed-out')

      // A refresh by hand still finds nobody signed in, and now the page
      // offers the button instead of the app reopening the window.
      const reads = browser.libraryReads
      expect((await post('/api/library', {}, {}, second.url)).status).toBe(202)
      state = await idle(second.url)
      expect(browser.libraryReads).toBe(reads + 1)
      expect(browser.logins).toBe(1)
      expect(state.amazon).toBe('signed-out')

      // The button itself always works.
      browser.loginConfirms = true
      browser.fallback = LIBRARY
      expect((await post('/api/login', {}, {}, second.url)).status).toBe(202)
      state = await idle(second.url)
      expect(browser.logins).toBe(2)
      expect(state.amazon).toBe('signed-in')
    } finally {
      await second.close()
    }
  })

  it('says so when another run holds the browser, without opening sign-in', async () => {
    await idle()
    browser.profileBusy = true

    const second = await createServeHandle(serveOptions())
    try {
      const state = await idle(second.url)
      expect(state.profileBusy).toBe(true)
      expect(state.libraryError).toMatch(/Another kindle-export/)
      expect(browser.logins).toBe(0)

      // Retry by hand once the other run is done.
      browser.profileBusy = false
      await post('/api/library', {}, {}, second.url)
      const after = await idle(second.url)
      expect(after.profileBusy).toBe(false)
      expect(after.libraryError).toBeUndefined()
      expect(after.library.books).toHaveLength(2)
    } finally {
      await second.close()
    }
  })

  it('starts a book clicked during the first library load once the load is done', async () => {
    vi.stubEnv('OPENAI_API_KEY', 'sk-test')
    await idle()
    browser.holdLibrary = true

    const second = await createServeHandle(serveOptions())
    try {
      await until(() => !!browser.releaseLibrary, 'the refresh to start')
      expect(
        (await post('/api/export', { asin: 'B00TEST' }, {}, second.url)).status
      ).toBe(202)
      expect(await queued(second.url)).toEqual(['B00TEST:queued'])
      expect(pipelineCalls).toHaveLength(0)

      browser.releaseLibrary!()
      await until(() => pipelineCalls.length === 1, 'the export to start')
      await idle(second.url)
      expect(await queued(second.url)).toEqual(['B00TEST:done'])
    } finally {
      browser.holdLibrary = false
      browser.releaseLibrary?.()
      await second.close()
    }
  })
})
