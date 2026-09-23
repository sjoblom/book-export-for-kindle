import { spawn } from 'node:child_process'
import fs from 'node:fs/promises'
import http from 'node:http'
import path from 'node:path'
import { pipeline } from 'node:stream/promises'

import { type BookStatus, scanBooks } from './book-status'
import { loadConfig, saveConfig } from './config'
import {
  hideBrowserWindow,
  isProfileBusyError,
  launchBrowserContext
} from './extract-kindle-book'
import {
  fetchLibrary,
  type LibraryBook,
  NotSignedInError
} from './kindle-library'
import { readLibraryCache, writeLibraryCache } from './library-cache'
import {
  bookFellShort,
  type Options,
  type PipelineEvent,
  processBook
} from './pipeline'
import { renderPage } from './serve-page'
import { interactiveLogin } from './session'
import { getEnv } from './utils'
import { isVisionOcrAvailable } from './vision-ocr'

/**
 * The local web app: the same pipeline as the CLI, driven from a browser.
 *
 * One process, two browser surfaces. The UI runs in the user's own browser (or
 * the Mac app's window) at a localhost URL; Amazon sign-in, reading the
 * library and page capture happen in a separate automated Chrome window. The
 * server only ever binds 127.0.0.1 — nothing here is reachable from the
 * network — and browser requests are checked against DNS-rebinding (Host
 * header) and cross-site (custom header) tricks, because a signed-in Amazon
 * session and an OpenAI key sit behind it.
 *
 * The app does as much as it can on its own, because the person using it may
 * not know what a step is for: it shows the library from the last launch
 * straight away, refreshes it in the background, opens Amazon's sign-in once
 * if that refresh finds nobody signed in, and exports a book as soon as it is
 * clicked, queueing any further clicks behind it.
 */

export const DEFAULT_PORT = 8484

/** Real ASINs are ten characters; the bound keeps junk out of paths and logs. */
const ASIN_REGEX = /^[A-Z0-9]{1,20}$/

/** Books waiting or exporting at once; nobody queues 500 books attended. */
const MAX_QUEUED_BOOKS = 50

/**
 * Finished books kept in the queue for their outcome (warnings, errors). The
 * files themselves are found by scanning the output folder, so dropping the
 * oldest of these loses nothing but a message.
 */
const MAX_FINISHED_BOOKS = 100

const MAX_BODY_BYTES = 64 * 1024
const MAX_LOG_ENTRIES = 250
const BROADCAST_DEBOUNCE_MS = 150
const SSE_HEARTBEAT_MS = 30_000

/**
 * When a terminal command holds the browser profile, the library refresh is
 * tried again this often, a limited number of times: long enough for a short
 * command to finish, and never an endless background loop.
 */
const BUSY_RETRY_MS = 30_000
const MAX_BUSY_RETRIES = 10

type AmazonState = 'unknown' | 'signing-in' | 'signed-in' | 'signed-out'

/**
 * What the shared browser profile is doing. Only one thing can use it at a
 * time — Chrome refuses to open a profile twice — so sign-in, the library
 * refresh and exports take turns. The Mac app reads `'export'` to decide
 * whether quitting needs a confirmation.
 */
type Busy = null | 'login' | 'library' | 'export'

export type BookJobStatus =
  | 'queued'
  | 'working'
  | 'capturing'
  | 'transcribing'
  | 'exporting'
  | 'done'
  | 'warning'
  | 'failed'

const FINISHED: ReadonlySet<BookJobStatus> = new Set<BookJobStatus>([
  'done',
  'warning',
  'failed'
])

export interface BookJobState {
  asin: string
  title: string
  status: BookJobStatus
  formats: Array<'md' | 'pdf'>
  /** This book is being re-captured from scratch rather than resumed. */
  forceCapture: boolean
  queuedAt: number
  finishedAt?: number
  captured?: number
  /** The book page the capture has reached, comparable with capturedTotal. */
  capturedPage?: number
  capturedTotal?: number
  transcribed?: number
  transcribedTotal?: number
  warnings: string[]
  outputs: string[]
  error?: string
}

export interface QueueState {
  /**
   * Every book asked for since the server started, in order: finished ones,
   * then the one being exported, then those still waiting. Asking for a
   * finished book again moves it to the end.
   */
  books: BookJobState[]
  /** Stop was pressed; the book being exported is the last one. */
  stopRequested: boolean
  log: Array<{ time: number; level: 'info' | 'warn'; message: string }>
}

interface AppState {
  platform: NodeJS.Platform
  outDir: string
  hasApiKey: boolean
  /** Pages can be read on this machine for free, without an API key. */
  localOcr: boolean
  /**
   * Whether reading pages needs an OpenAI key: always without local OCR, and
   * with it only when `serve` was started with a model. The key form is shown
   * only when this is true, so the common case never sees it.
   */
  needsApiKey: boolean
  /** Exports also write a PDF next to the Markdown. */
  alsoPdf: boolean
  amazon: AmazonState
  busy: Busy
  /** `fromCache` until the background refresh has replaced it. */
  library?: { books: LibraryBook[]; fetchedAt: number; fromCache: boolean }
  libraryError?: string
  /**
   * Another kindle-export holds the browser profile. The refresh is retried
   * by itself, so the page can say "trying again shortly" rather than asking
   * for something the person can't do anything about.
   */
  profileBusy: boolean
  /** Why the last sign-in attempt could not open a browser at all. */
  amazonError?: string
  diskBooks: BookStatus[]
  queue: QueueState
}

export interface ServeHandle {
  server: http.Server
  url: string
  close: () => Promise<void>
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}

export interface ExportRequest {
  asin: string
  /** Absent means "the usual": Markdown, plus PDF where the settings say so. */
  formats?: Array<'md' | 'pdf'>
  /**
   * Throw the existing page images away and read the book again.
   *
   * The web app's only remedy for a capture that stopped part-way: reusing
   * those pages produces the same truncated book however many times it is
   * asked. Off for an ordinary export, which resumes page by page.
   */
  forceCapture: boolean
}

function parseAsin(value: unknown): string {
  if (typeof value !== 'string' || !ASIN_REGEX.test(value)) {
    throw new HttpError(400, `invalid ASIN: ${String(value).slice(0, 40)}`)
  }

  return value
}

/**
 * Validate an export request from the page: one book, which joins the queue.
 *
 * Separate from queueing it so it can be tested without a browser, and so
 * every rejection happens before anything is launched.
 */
export function parseExportRequest(body: any): ExportRequest {
  if (!body || typeof body !== 'object') {
    throw new HttpError(400, 'expected a JSON object')
  }
  const asin = parseAsin(body.asin)

  let formats: Array<'md' | 'pdf'> | undefined
  if (body.formats !== undefined) {
    if (!Array.isArray(body.formats)) {
      throw new HttpError(400, 'formats must be a list')
    }
    formats = [
      ...new Set(
        body.formats.filter(
          (f: unknown): f is 'md' | 'pdf' => f === 'md' || f === 'pdf'
        )
      )
    ] as Array<'md' | 'pdf'>
    if (!formats.length) throw new HttpError(400, 'no known format requested')
  }

  // Re-capturing a book costs an hour of browser time, so it happens only when
  // the page asked for it in so many words — anything else is an ordinary
  // resuming export.
  const forceCapture = body.forceCapture === true

  return { asin, formats, forceCapture }
}

export async function createServeHandle(
  options: Options,
  { openBrowser = false }: { openBrowser?: boolean } = {}
): Promise<ServeHandle> {
  const app = new App(options)
  await app.init()

  const server = http.createServer((req, res) => {
    void app.handle(req, res)
  })

  const port = options.port ?? DEFAULT_PORT
  let url: string
  try {
    url = await new Promise<string>((resolve, reject) => {
      server.once('error', reject)
      server.listen(port, '127.0.0.1', () => {
        const address = server.address()
        const boundPort =
          address && typeof address === 'object' ? address.port : port
        resolve(`http://localhost:${boundPort}`)
      })
    })
  } catch (err) {
    // The library refresh started in init() has a timer or browser behind it;
    // a server that never listened must not leave those running.
    app.dispose()
    throw err
  }

  // The .app launcher opens the page itself once the port answers, so it asks
  // the server to stay out of the way rather than opening a second tab.
  if (openBrowser && getEnv('KINDLE_EXPORT_NO_OPEN') !== '1') {
    openInBrowser(url)
  }

  return {
    server,
    url,
    close: async () => {
      app.dispose()
      // Keep-alive sockets from the browser would otherwise hold the server
      // open long after the last request.
      server.closeAllConnections()
      await new Promise<void>((resolve) => {
        server.close(() => {
          resolve()
        })
      })
    }
  }
}

/** `kindle-export serve`: start the app, open it, and stay up. */
export async function startServer(options: Options): Promise<void> {
  let handle: ServeHandle
  try {
    handle = await createServeHandle(options, { openBrowser: true })
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'EADDRINUSE') {
      const port = options.port ?? DEFAULT_PORT
      console.error(
        `Port ${port} is already in use — is kindle-export serve already running?`
      )
      console.error(
        `If so, open http://localhost:${port} — otherwise pass --port to pick another.`
      )
      process.exitCode = 1
      return
    }

    throw err
  }

  console.log(`kindle-export is running at ${handle.url}`)
  console.log(
    'Opening it in your browser. Keep this window open while it runs;'
  )
  console.log('press Ctrl+C to stop.')

  // Stay alive until the process is killed.
  await new Promise<void>(() => {})
}

function openInBrowser(url: string): void {
  const [cmd, args] =
    process.platform === 'darwin'
      ? ['open', [url]]
      : process.platform === 'win32'
        ? ['cmd', ['/c', 'start', '', url]]
        : ['xdg-open', [url]]

  try {
    spawn(cmd as string, args as string[], {
      stdio: 'ignore',
      detached: true
    }).unref()
  } catch {
    // The printed URL is the fallback.
  }
}

type RefreshOutcome = 'ok' | 'signed-out' | 'profile-busy' | 'error'

class App {
  private readonly options: Options
  private amazon: AmazonState = 'unknown'
  private busy: Busy = null
  private library?: {
    books: LibraryBook[]
    fetchedAt: number
    fromCache: boolean
  }

  private libraryError?: string
  private profileBusy = false
  private amazonError?: string
  private diskBooks: BookStatus[] = []
  private localOcr = false
  private alsoPdf = false
  private readonly queue: QueueState = {
    books: [],
    stopRequested: false,
    log: []
  }

  /**
   * The sign-in window opens by itself at most once per server start. A
   * second automatic window after the person closed the first would feel
   * like the app fighting them; from then on the page offers a button.
   */
  private autoSignInUsed = false
  private busyRetries = 0
  private retryTimer?: NodeJS.Timeout
  /** A retry came due while an export held the browser; run it afterwards. */
  private refreshAfterQueue = false
  private disposed = false

  private readonly sseClients = new Set<http.ServerResponse>()
  private broadcastTimer?: NodeJS.Timeout

  constructor(options: Options) {
    this.options = options
  }

  /**
   * Show what is already known — the cached library, the books on disk — and
   * start finding out the rest in the background. Nothing here waits on
   * Chrome, so the page is up in the time it takes to read two files.
   */
  async init(): Promise<void> {
    this.localOcr = await isVisionOcrAvailable()
    this.alsoPdf = (await loadConfig()).alsoPdf === true

    const cached = await readLibraryCache(this.options.profileDir)
    if (cached) this.library = { ...cached, fromCache: true }

    await this.refreshDiskBooks()
    this.startLibraryRefresh()
  }

  dispose(): void {
    this.disposed = true
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.retryTimer = undefined
    if (this.broadcastTimer) clearTimeout(this.broadcastTimer)
    this.broadcastTimer = undefined
    for (const client of this.sseClients) {
      client.end()
    }
    this.sseClients.clear()
  }

  /**
   * Naming a model means OpenAI reads the pages, which needs a key. Otherwise
   * local OCR covers it, and the key is beside the point.
   *
   * The model can only come from the `serve` command line or OCR_MODEL, never
   * from the page: switching to a paid API is a power-user decision, not a
   * setting someone should be able to flip by accident.
   */
  private needsApiKey(): boolean {
    return !this.localOcr || !!this.options.model
  }

  // ---------------------------------------------------------------- state

  private uiState(): AppState {
    return {
      platform: process.platform,
      outDir: path.resolve(this.options.outDir),
      hasApiKey: !!getEnv('OPENAI_API_KEY'),
      localOcr: this.localOcr,
      needsApiKey: this.needsApiKey(),
      alsoPdf: this.alsoPdf,
      amazon: this.amazon,
      busy: this.busy,
      library: this.library,
      libraryError: this.libraryError,
      profileBusy: this.profileBusy,
      amazonError: this.amazonError,
      diskBooks: this.diskBooks,
      queue: this.queue
    }
  }

  private async refreshDiskBooks(): Promise<void> {
    this.diskBooks = await scanBooks(this.options.outDir)
  }

  private broadcast(): void {
    if (this.broadcastTimer || this.disposed) return

    this.broadcastTimer = setTimeout(() => {
      this.broadcastTimer = undefined
      const frame = `data: ${JSON.stringify(this.uiState())}\n\n`
      for (const client of this.sseClients) {
        client.write(frame)
      }
    }, BROADCAST_DEBOUNCE_MS)
    this.broadcastTimer.unref?.()
  }

  private queueLog(level: 'info' | 'warn', asin: string, message: string) {
    const { log } = this.queue
    log.push({ time: Date.now(), level, message: `[${asin}] ${message}` })
    if (log.length > MAX_LOG_ENTRIES) {
      log.splice(0, log.length - MAX_LOG_ENTRIES)
    }
  }

  // ------------------------------------------------------------- security

  /**
   * Reject requests that didn't come from this machine's own browser hitting
   * the localhost origin. The Host check stops DNS rebinding (a public
   * hostname resolving to 127.0.0.1); the custom-header check on writes stops
   * cross-site requests, since no other origin can attach it without passing
   * a CORS preflight we never grant.
   */
  private checkRequest(req: http.IncomingMessage): void {
    const host = (req.headers.host ?? '').replace(/:\d+$/, '')
    if (host !== 'localhost' && host !== '127.0.0.1' && host !== '[::1]') {
      throw new HttpError(403, 'forbidden host')
    }

    if (req.method === 'POST' && req.headers['x-kindle-export'] !== '1') {
      throw new HttpError(403, 'missing app header')
    }
  }

  private async readBody(req: http.IncomingMessage): Promise<any> {
    const chunks: Buffer[] = []
    let size = 0
    for await (const chunk of req) {
      size += (chunk as Buffer).length
      if (size > MAX_BODY_BYTES) throw new HttpError(413, 'body too large')
      chunks.push(chunk as Buffer)
    }

    if (!size) return {}
    try {
      return JSON.parse(Buffer.concat(chunks).toString('utf8'))
    } catch {
      throw new HttpError(400, 'invalid JSON body')
    }
  }

  // -------------------------------------------------------------- routing

  async handle(
    req: http.IncomingMessage,
    res: http.ServerResponse
  ): Promise<void> {
    try {
      this.checkRequest(req)

      const url = new URL(req.url ?? '/', 'http://localhost')
      const route = `${req.method} ${url.pathname}`

      if (route === 'GET /') {
        res.writeHead(200, {
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'no-store'
        })
        res.end(renderPage())
        return
      }

      if (route === 'GET /api/state') {
        if (url.searchParams.has('scan')) await this.refreshDiskBooks()
        this.json(res, 200, this.uiState())
        return
      }

      if (route === 'GET /api/events') {
        this.handleSse(req, res)
        return
      }

      if (route === 'POST /api/config') {
        await this.handleConfig(await this.readBody(req))
        this.json(res, 200, this.uiState())
        return
      }

      if (route === 'POST /api/login') {
        this.startLogin()
        this.json(res, 202, this.uiState())
        return
      }

      if (route === 'POST /api/library') {
        if (this.busy === 'export') {
          throw new HttpError(
            409,
            'Your books are being exported — the list can refresh once that is done.'
          )
        }
        if (this.busy === 'login') {
          throw new HttpError(409, 'Finish signing in to Amazon first.')
        }
        this.busyRetries = 0
        this.startLibraryRefresh()
        this.json(res, 202, this.uiState())
        return
      }

      if (route === 'POST /api/export') {
        this.enqueue(await this.readBody(req))
        this.json(res, 202, this.uiState())
        return
      }

      if (route === 'POST /api/queue/remove') {
        this.removeFromQueue(await this.readBody(req))
        this.json(res, 200, this.uiState())
        return
      }

      if (route === 'POST /api/queue/stop') {
        this.stopQueue()
        this.json(res, 200, this.uiState())
        return
      }

      if (route === 'POST /api/reveal') {
        await this.handleReveal(await this.readBody(req))
        this.json(res, 200, {})
        return
      }

      if (req.method === 'GET' && url.pathname.startsWith('/api/download/')) {
        await this.handleDownload(url.pathname, res)
        return
      }

      throw new HttpError(404, 'not found')
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500
      const message =
        err instanceof HttpError
          ? err.message
          : ((err as Error)?.message ?? 'internal error')
      if (!res.headersSent) {
        this.json(res, status, { error: message })
      } else {
        res.end()
      }
    }
  }

  private json(res: http.ServerResponse, status: number, body: unknown): void {
    res.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store'
    })
    res.end(JSON.stringify(body))
  }

  private handleSse(req: http.IncomingMessage, res: http.ServerResponse): void {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-store',
      connection: 'keep-alive'
    })
    res.write(`retry: 1000\n\n`)
    res.write(`data: ${JSON.stringify(this.uiState())}\n\n`)

    this.sseClients.add(res)
    const heartbeat = setInterval(() => {
      res.write(`: ping\n\n`)
    }, SSE_HEARTBEAT_MS)
    heartbeat.unref?.()

    req.on('close', () => {
      clearInterval(heartbeat)
      this.sseClients.delete(res)
    })
  }

  // ------------------------------------------------------------- handlers

  private async handleConfig(body: any): Promise<void> {
    // Only the key and the PDF preference are accepted. A `model` from an
    // older page is ignored on purpose: see needsApiKey for why the page can't
    // choose one.
    const apiKey =
      typeof body?.apiKey === 'string' ? body.apiKey.trim() : undefined
    const alsoPdf =
      typeof body?.alsoPdf === 'boolean' ? body.alsoPdf : undefined

    const stored = await loadConfig()
    await saveConfig({
      ...stored,
      openaiApiKey: apiKey || stored.openaiApiKey,
      ...(alsoPdf === undefined ? {} : { alsoPdf })
    })
    if (alsoPdf !== undefined) this.alsoPdf = alsoPdf

    // The transcriber reads the key from the environment at run time, so a
    // key saved here must work without restarting the server.
    if (apiKey) {
      // eslint-disable-next-line no-process-env
      process.env.OPENAI_API_KEY = apiKey
    }
    this.broadcast()
  }

  // ---------------------------------------------------- amazon & library

  private startLogin(): void {
    if (this.busy === 'export') {
      throw new HttpError(409, 'an export is running — wait for it to finish')
    }
    if (this.busy) {
      throw new HttpError(409, 'the browser window is busy — close it or wait')
    }

    this.runLogin()
  }

  /**
   * Refresh the library in a minimized Chrome window.
   *
   * Skipped while an export runs: the export has the browser profile, and
   * books clicked meanwhile shouldn't wait behind a refresh they didn't ask
   * for. A refresh already under way is simply joined.
   */
  private startLibraryRefresh(): void {
    if (this.disposed || this.busy === 'library') return
    if (this.busy) {
      this.refreshAfterQueue = true
      return
    }
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.retryTimer = undefined

    this.busy = 'library'
    this.broadcast()

    void (async () => {
      let signInNext = false
      try {
        const outcome = await this.fetchLibraryOnce()
        // The first "not signed in" of this run opens Amazon's sign-in by
        // itself: the person may not know that is the step they are missing.
        if (outcome === 'signed-out' && !this.autoSignInUsed) {
          this.autoSignInUsed = true
          signInNext = !this.disposed
        }
      } finally {
        if (signInNext) {
          // Straight from one browser task into the next, so a book clicked
          // in the meantime can't grab the profile in between.
          this.runLogin()
        } else {
          this.releaseBrowser()
        }
      }
    })()
  }

  /**
   * Open the sign-in window, and once Amazon confirms the session, read the
   * library with it. Assumes the caller checked the browser is free.
   */
  private runLogin(): void {
    const before = this.amazon
    this.autoSignInUsed = true
    this.busy = 'login'
    this.amazon = 'signing-in'
    this.amazonError = undefined
    this.broadcast()

    void (async () => {
      try {
        let confirmed = false
        try {
          confirmed = await interactiveLogin(this.options.profileDir)
        } catch (err) {
          // The one failure that isn't the user closing the window: a
          // terminal command is holding the browser profile. Nothing was tried
          // against Amazon, so say what to do rather than guessing.
          if (isProfileBusyError(err)) this.amazonError = describeBusyProfile()
        }

        if (!confirmed || this.disposed) {
          // Closing the window is an answer, not a new fact about the
          // session: whatever was known before still holds.
          this.amazon = before === 'signing-in' ? 'unknown' : before
          return
        }

        this.amazon = 'signed-in'
        this.busy = 'library'
        this.broadcast()
        await this.fetchLibraryOnce()
      } finally {
        this.releaseBrowser()
      }
    })()
  }

  /**
   * One library read, recording its outcome in the app state. Never throws:
   * every failure becomes something the page can show.
   */
  private async fetchLibraryOnce(): Promise<RefreshOutcome> {
    this.libraryError = undefined
    this.profileBusy = false

    let context: Awaited<ReturnType<typeof launchBrowserContext>> | undefined
    try {
      context = await launchBrowserContext({
        profileDir: this.options.profileDir
      })
    } catch (err) {
      if (isProfileBusyError(err)) {
        this.profileBusy = true
        this.libraryError = describeBusyProfile()
        this.scheduleBusyRetry()
        return 'profile-busy'
      }
      this.libraryError = (err as Error)?.message ?? String(err)
      return 'error'
    }

    try {
      // The library fetch needs no interaction, so keep its window out of
      // the way. fetchLibrary reuses this same page.
      const page = context.pages()[0] ?? (await context.newPage())
      await hideBrowserWindow(page)

      const books = await fetchLibrary(context)
      const fetchedAt = Date.now()
      this.library = { books, fetchedAt, fromCache: false }
      this.amazon = 'signed-in'
      this.busyRetries = 0
      await writeLibraryCache(this.options.profileDir, { books, fetchedAt })
      return 'ok'
    } catch (err) {
      if (err instanceof NotSignedInError) {
        this.amazon = 'signed-out'
        return 'signed-out'
      }
      this.libraryError = (err as Error)?.message ?? String(err)
      return 'error'
    } finally {
      await context.close().catch(() => {})
      await context
        .browser()
        ?.close()
        .catch(() => {})
    }
  }

  private scheduleBusyRetry(): void {
    if (this.disposed || this.busyRetries >= MAX_BUSY_RETRIES) return
    this.busyRetries++

    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined
      this.startLibraryRefresh()
    }, BUSY_RETRY_MS)
    this.retryTimer.unref?.()
  }

  /** A browser task ended; hand the profile to whatever is waiting for it. */
  private releaseBrowser(): void {
    this.busy = null
    this.broadcast()
    this.pump()
  }

  // ---------------------------------------------------------------- queue

  private enqueue(body: any): void {
    if (this.needsApiKey() && !getEnv('OPENAI_API_KEY')) {
      throw new HttpError(400, 'store an OpenAI API key in Settings first')
    }

    const request = parseExportRequest(body)
    const { books } = this.queue

    // A second click on a book that is already waiting or exporting is the
    // same request again, not a second export.
    if (
      books.some(
        (book) => book.asin === request.asin && !FINISHED.has(book.status)
      )
    ) {
      return
    }

    const pending = books.filter((book) => !FINISHED.has(book.status)).length
    if (pending >= MAX_QUEUED_BOOKS) {
      throw new HttpError(
        400,
        `at most ${MAX_QUEUED_BOOKS} books can wait at once`
      )
    }

    // Asking for a finished book again replaces its old outcome.
    this.queue.books = books.filter((book) => book.asin !== request.asin)
    this.queue.books.push({
      asin: request.asin,
      title: this.titleFor(request.asin),
      status: 'queued',
      formats: request.formats ?? this.formatsFor(request.asin),
      forceCapture: request.forceCapture,
      queuedAt: Date.now(),
      warnings: [],
      outputs: []
    })

    // Stop already cleared everything that was waiting; a book clicked after
    // it is a fresh request and should run once the current one is done.
    this.queue.stopRequested = false

    const finished = this.queue.books.filter((book) =>
      FINISHED.has(book.status)
    )
    if (finished.length > MAX_FINISHED_BOOKS) {
      const drop = new Set(finished.slice(0, -MAX_FINISHED_BOOKS))
      this.queue.books = this.queue.books.filter((book) => !drop.has(book))
    }

    this.broadcast()
    this.pump()
  }

  private removeFromQueue(body: any): void {
    const asin = parseAsin(body?.asin)
    const book = this.queue.books.find(
      (entry) => entry.asin === asin && !FINISHED.has(entry.status)
    )
    if (!book) throw new HttpError(404, 'that book is not waiting to export')
    if (book.status !== 'queued') {
      throw new HttpError(
        409,
        'that book is already being exported — use Stop to end after it'
      )
    }

    this.queue.books = this.queue.books.filter((entry) => entry !== book)
    this.broadcast()
  }

  /**
   * "Stop after this book": everything still waiting is taken off the queue
   * now, and the book being exported finishes. Cutting a capture off
   * mid-book would only leave a truncated book that needs capturing again.
   */
  private stopQueue(): void {
    const before = this.queue.books.length
    this.queue.books = this.queue.books.filter(
      (book) => book.status !== 'queued'
    )
    const active = this.queue.books.some((book) => !FINISHED.has(book.status))
    if (active) this.queue.stopRequested = true
    if (active || this.queue.books.length !== before) this.broadcast()
  }

  /** Markdown always; PDF when the settings ask, or the book already has one. */
  private formatsFor(asin: string): Array<'md' | 'pdf'> {
    const hasPdf = this.diskBooks
      .find((book) => book.asin === asin)
      ?.exports.some((file) => file.format === 'pdf')

    return this.alsoPdf || hasPdf ? ['md', 'pdf'] : ['md']
  }

  private titleFor(asin: string): string {
    return (
      this.library?.books.find((book) => book.asin === asin)?.title ??
      this.diskBooks.find((book) => book.asin === asin)?.title ??
      asin
    )
  }

  /**
   * Start exporting if a book is waiting and the browser is free. Called
   * whenever either might have changed; a book clicked while the library is
   * still loading simply starts when the refresh lets go of the browser.
   */
  private pump(): void {
    if (this.disposed || this.busy) return

    if (!this.queue.books.some((book) => book.status === 'queued')) {
      if (this.refreshAfterQueue) {
        this.refreshAfterQueue = false
        this.startLibraryRefresh()
      }
      return
    }

    this.busy = 'export'
    this.broadcast()
    void this.runQueue()
  }

  private async runQueue(): Promise<void> {
    try {
      for (;;) {
        const book = this.queue.books.find((entry) => entry.status === 'queued')
        if (!book || this.disposed) break

        await this.exportBook(book)
      }
    } finally {
      this.queue.stopRequested = false
      this.releaseBrowser()
    }
  }

  private async exportBook(book: BookJobState): Promise<void> {
    book.status = 'working'
    this.broadcast()

    // Settings may have changed since the server started; the stored config
    // is what the settings screen writes, so read it fresh per book.
    const stored = await loadConfig()
    const bookOptions: Options = {
      ...this.options,
      command: 'all',
      asins: [book.asin],
      formats: book.formats,
      concurrency: this.options.concurrency ?? stored.concurrency,
      // A re-capture throws the pages away and reads the book from the start,
      // which is the only way out of a capture that stopped early. It also
      // drops the old transcription, so nothing from the truncated book
      // survives into the new export.
      forceCapture: book.forceCapture,
      forceOcr: false,
      forceExport: false,
      // Keep the capture window minimized: from the web app's point of view a
      // self-driving browser on top of the page is an invitation to close it.
      hideBrowser: true
    }

    try {
      const result = await processBook(book.asin, bookOptions, (event) => {
        this.onBookEvent(book, event)
      })

      book.outputs = result.outputs.map((file) => path.basename(file))
      // The same verdict the CLI's exit status uses, so a book badged
      // "done" here is a book the terminal would have called finished.
      book.status = bookFellShort(result, bookOptions.command)
        ? 'warning'
        : 'done'
    } catch (err) {
      book.status = 'failed'
      book.error = (err as Error)?.message ?? String(err)
      this.queueLog('warn', book.asin, `failed: ${book.error}`)
    }

    book.finishedAt = Date.now()
    await this.refreshDiskBooks()
    this.broadcast()
  }

  private onBookEvent(book: BookJobState, event: PipelineEvent): void {
    switch (event.kind) {
      case 'stage':
        book.status =
          event.stage === 'capture'
            ? 'capturing'
            : event.stage === 'transcribe'
              ? 'transcribing'
              : 'exporting'
        break
      case 'capture-progress':
        book.captured = event.captured
        book.capturedPage = event.page
        book.capturedTotal = event.total
        break
      case 'transcribe-progress':
        book.transcribed = event.done
        book.transcribedTotal = event.total
        break
      case 'info':
        this.queueLog('info', book.asin, event.message)
        break
      case 'warn':
        book.warnings.push(event.message)
        this.queueLog('warn', book.asin, event.message)
        break
    }

    this.broadcast()
  }

  private async handleReveal(body: any): Promise<void> {
    if (process.platform !== 'darwin') {
      throw new HttpError(400, 'only available on macOS')
    }

    const asin = typeof body.asin === 'string' ? body.asin : ''
    if (asin && !ASIN_REGEX.test(asin)) {
      throw new HttpError(400, 'invalid ASIN')
    }

    const dir = asin
      ? path.join(this.options.outDir, asin)
      : this.options.outDir
    await fs.access(dir).catch(() => {
      throw new HttpError(404, 'no such folder')
    })

    spawn('open', [dir], { stdio: 'ignore', detached: true }).unref()
  }

  private async handleDownload(
    pathname: string,
    res: http.ServerResponse
  ): Promise<void> {
    const parts = pathname.split('/').slice(3) // ['', 'api', 'download', ...]
    if (parts.length !== 2) throw new HttpError(400, 'bad download path')

    const asin = decodeURIComponent(parts[0]!)
    const name = decodeURIComponent(parts[1]!)

    if (!ASIN_REGEX.test(asin)) throw new HttpError(400, 'invalid ASIN')
    // The filename comes back from the browser, so treat it as hostile: no
    // separators, no traversal, only the two formats we ever write.
    if (
      name.includes('/') ||
      name.includes('\\') ||
      name.includes('..') ||
      !/\.(md|pdf)$/.test(name)
    ) {
      throw new HttpError(400, 'invalid file name')
    }

    const bookDir = path.resolve(this.options.outDir, asin)
    const filePath = path.resolve(bookDir, name)
    if (path.dirname(filePath) !== bookDir) {
      throw new HttpError(400, 'invalid file name')
    }

    // Open first and ask the open file what it is, so the check and the read
    // are about the same thing: a stat() by path can be answered by one file
    // and the read served by another (or by nothing) if the folder changes in
    // between. Anything unopenable is simply not there as far as the page is
    // concerned.
    const file = await fs.open(filePath, 'r').catch(() => {
      throw new HttpError(404, 'file not found')
    })
    let stat: Awaited<ReturnType<typeof file.stat>>
    try {
      stat = await file.stat()
      // A folder called `x.md` passes every name check, and reading it fails
      // only once the stream starts — after the 200 has gone out.
      if (!stat.isFile()) throw new HttpError(404, 'file not found')
    } catch (err) {
      await file.close().catch(() => {})
      throw err
    }

    const headers: http.OutgoingHttpHeaders = {
      'content-type': name.endsWith('.pdf')
        ? 'application/pdf'
        : 'text/markdown; charset=utf-8',
      'content-length': stat.size,
      'content-disposition': contentDisposition(name),
      'cache-control': 'no-store'
    }

    // Node validates header values here, not when the object is built. A
    // refusal must surface as an ordinary error response: the file's
    // content-length has not been promised yet, so the body isn't truncated.
    try {
      res.writeHead(200, headers)
    } catch (err) {
      await file.close().catch(() => {})
      throw new HttpError(
        500,
        `invalid download headers: ${(err as Error).message}`
      )
    }

    // pipe() leaves a read error with no listener, which Node turns into an
    // uncaught exception that takes the whole server down. pipeline() routes
    // it here instead and destroys both ends: the browser sees a failed
    // download (not a short file passed off as complete), and the file is
    // closed. A reader who cancels the download lands here too.
    await pipeline(file.createReadStream(), res).catch(() => {})
  }
}

/**
 * The browser profile is held by a kindle-export run outside this app — the
 * server's own jobs are excluded by `requireIdle`, so this is a terminal
 * command. A pid means nothing to the person reading the page; what they can
 * act on is the other window.
 */
function describeBusyProfile(): string {
  return (
    'Another kindle-export is using the browser right now. ' +
    'Wait for it to finish, or close its Chrome window, then try again.'
  )
}

/**
 * A `Content-Disposition` a browser and Node both accept.
 *
 * Node rejects header values holding anything outside Latin-1, and an export
 * can be renamed to anything at all — so the plain `filename` parameter carries
 * an ASCII-only stand-in and the real name travels percent-encoded in
 * `filename*`, which every current browser prefers anyway.
 */
function contentDisposition(name: string): string {
  return `attachment; filename="${asciiFallbackName(name)}"; filename*=UTF-8''${encodeRfc5987(name)}`
}

/** `name` reduced to printable ASCII, never empty, keeping its extension. */
function asciiFallbackName(name: string): string {
  const ext = name.toLowerCase().endsWith('.pdf') ? '.pdf' : '.md'
  const stem = name
    .slice(0, Math.max(0, name.length - ext.length))
    // Control characters, quotes and separators would all break the quoted
    // string; a name of nothing but those leaves the generic fallback.
    .replaceAll(/[^\u0020-\u007E]/g, '')
    .replaceAll(/["\\;]/g, '')
    .trim()

  return `${stem || 'book'}${ext}`
}

/** Percent-encoding for the `filename*` ext-value of RFC 5987. */
function encodeRfc5987(name: string): string {
  return encodeURIComponent(name).replaceAll(
    /['()*!]/g,
    (c) => `%${c.codePointAt(0)!.toString(16).toUpperCase()}`
  )
}
