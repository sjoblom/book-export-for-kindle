#!/usr/bin/env node
import 'dotenv/config'

import { realpathSync } from 'node:fs'
import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { checkbox, confirm, input, password } from '@inquirer/prompts'

import { isBookBusyError, withBookLock } from './book-lock'
import { bookCompleteness } from './capture-status'
import { cleanPageImages, cleanRenderData, formatBytes } from './cleanup'
import { loadConfig, saveConfig } from './config'
import { readContentStore } from './content-store'
import { isProfileBusyError, launchBrowserContext } from './extract-kindle-book'
import { fetchLibrary, type LibraryBook } from './kindle-library'
import {
  applyConfig,
  bookFellShort,
  EMPTY_OPTIONS,
  type Options,
  type PipelineEvent,
  processBook,
  readMetadata
} from './pipeline'
import { startServer } from './serve'
import { interactiveLogin } from './session'
import { assert, isPositiveInteger } from './utils'
import { isVisionOcrAvailable } from './vision-ocr'

export { applyConfig, type Options } from './pipeline'

const VERSION = '0.3.0'

const HELP = `book-export — export Kindle books you own as markdown

Usage
  book-export setup                    choose where books go, then sign in
  book-export serve                    open the web app in your browser
  book-export                          pick books from your library, then export
  book-export <ASIN...>                capture, transcribe and export (resumes)
  book-export login                    sign in to Amazon once, storing the session
  book-export list                     list the books in your Kindle library
  book-export clean [ASIN...]          delete working files, keeping the text
  book-export capture <ASIN...>        capture page images only
  book-export ocr <ASIN...>            transcribe captured pages only
  book-export export <ASIN...>         render markdown from transcribed text only

Options
  --format <md|pdf>      output format(s), comma separated (default: md)
  --json                 with 'list', print JSON instead of a table
  --limit <n>            with 'list', stop after this many books
  --out-dir <dir>        where books are written (default: ./out)
  --profile-dir <dir>    browser profile holding your session
                         (default: ~/.kindle-export/profile)
  --model <name>         read pages with an OpenAI model instead of locally
                         (needs an API key; also OCR_MODEL in the environment)
  --concurrency <n>      pages transcribed in parallel (default: 16)
  --port <n>             with 'serve', the port to listen on (default: 8484)
  --force                redo every stage, ignoring existing output
  --force-capture        redo page capture
  --force-ocr            redo transcription
  --keep-pages           keep page images instead of deleting them once
                         every page has been transcribed
  -h, --help             show this help
  -v, --version          show the version

The web app ('book-export serve') does the same in a browser: it shows your
Kindle library, and clicking a book exports it, ready to download.

On macOS, pages are read on this machine for free using Apple's Vision
framework — no API key, no model to choose, no per-page cost. Reading them
with OpenAI instead is an explicit choice per run: pass --model (or set
OCR_MODEL), which needs an API key. Elsewhere, OpenAI is the only way to read
pages, so 'setup' asks for a key there.

Run 'book-export login' to sign in to Amazon; the session stays on this
machine. 'book-export setup' stores the output folder (and the key, where
one is needed) in ~/.kindle-export/config.json. Settings can also come from
flags or a .env file, which take precedence.

Page images are deleted once a book is fully transcribed, since re-capturing
costs time rather than data. Pass --keep-pages to hold on to them.

Examples
  book-export setup
  book-export serve
  book-export                          pick from a menu of your books
  book-export list --json
  book-export B01H4G2J1U
  book-export B01H4G2J1U B07PPW5V9C --force-ocr
  book-export ocr B01H4G2J1U --model gpt-5-mini`

const COMMANDS = new Set([
  'setup',
  'serve',
  'login',
  'list',
  'clean',
  'capture',
  'ocr',
  'export'
])

/** Above this many books, offer to filter before showing the picker. */
const FILTER_PROMPT_THRESHOLD = 30

const ASIN_REGEX = /^[A-Z0-9]+$/

/** Books that produced output but are missing part of the book. */
const incompleteBooks = new Set<string>()

export function parseArgs(argv: string[]): Options | undefined {
  const positional: string[] = []
  let outDir: string | undefined
  let profileDir: string | undefined
  let model: string | undefined
  let concurrency: number | undefined
  let keepPages = false
  let json = false
  let limit: number | undefined
  let port: number | undefined
  let formats: Array<'md' | 'pdf'> = ['md']
  let force = false
  let forceCapture = false
  let forceOcr = false

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!
    const next = () => {
      const value = argv[++i]
      assert(value, `${arg} requires a value`)
      return value
    }

    switch (arg) {
      case '-h':
      case '--help':
        console.log(HELP)
        return
      case '-v':
      case '--version':
        console.log(VERSION)
        return
      case '--out-dir':
        outDir = next()
        break
      case '--profile-dir':
        profileDir = next()
        break
      case '--model':
        model = next()
        break
      case '--concurrency':
        // Checked here because p-map only rejects it once transcription
        // starts, which is after a capture that can take an hour.
        concurrency = parsePositiveInteger(arg, next())
        break
      case '--json':
        json = true
        break
      case '--limit':
        limit = parsePositiveInteger(arg, next())
        break
      case '--port':
        port = Number.parseInt(next(), 10)
        assert(
          Number.isInteger(port) && port > 0 && port < 65_536,
          `--port requires a number between 1 and 65535`
        )
        break
      case '--format': {
        const requested = next()
          .split(',')
          .map((value) => value.trim().toLowerCase())
        for (const value of requested) {
          assert(
            value === 'md' || value === 'pdf',
            `unknown format: ${value} (expected md or pdf)`
          )
        }

        formats = requested as Array<'md' | 'pdf'>
        break
      }
      case '--force':
        force = true
        break
      case '--force-capture':
      case '--force-extract':
        forceCapture = true
        break
      case '--force-ocr':
        forceOcr = true
        break
      case '--force-export':
        // Export always rewrites its output, so there's nothing to force. Still
        // accepted so existing scripts that pass it don't start failing.
        break
      case '--keep-pages':
        keepPages = true
        break
      default:
        assert(!arg.startsWith('-'), `unknown option: ${arg}`)
        positional.push(arg)
    }
  }

  const command =
    positional.length && COMMANDS.has(positional[0]!.toLowerCase())
      ? positional.shift()!.toLowerCase()
      : 'all'

  const asins = positional
    .map((asin) => asin.trim().toUpperCase())
    .filter(Boolean)
  for (const asin of asins) {
    // An ASIN is alphanumeric, and it's also used as a directory name — so
    // without this, a typo like `clean ..` resolves outside the book folder and
    // deletes something that has nothing to do with the export.
    assert(ASIN_REGEX.test(asin), `invalid ASIN: ${asin}`)
  }

  return {
    command,
    asins,
    outDir: outDir!,
    profileDir: profileDir!,
    model,
    concurrency,
    json,
    limit,
    port,
    formats,
    keepPages,
    forceCapture: force || forceCapture,
    forceOcr: force || forceOcr,
    forceExport: force
  }
}

/**
 * Strict where parseInt isn't: `8x` or `1.5` would otherwise pass as 8 or 1,
 * and `x` as NaN that fails far from the flag that caused it.
 */
function parsePositiveInteger(flag: string, raw: string): number {
  const value = Number(raw)
  assert(
    /^\d+$/.test(raw.trim()) && isPositiveInteger(value),
    `${flag} requires a positive whole number`
  )
  return value
}

function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000)
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`
}

/**
 * Render pipeline events the way this CLI always has: prefixed lines, errors
 * on stderr, transcription progress throttled to one line per 10%.
 */
function renderEvents(asin: string): (event: PipelineEvent) => void {
  let lastReport = 0

  return (event) => {
    switch (event.kind) {
      case 'info':
        console.log(`[${asin}] ${event.message}`)
        break
      case 'warn':
        console.error(`[${asin}] ${event.message}`)
        break
      case 'transcribe-progress': {
        const { done, total } = event
        const step = Math.max(1, Math.floor(total / 10))
        if (done === total || done - lastReport >= step) {
          lastReport = done
          console.log(`[${asin}] transcribe: ${done}/${total} pages`)
        }

        break
      }

      // The extractor narrates capture in the terminal already, and stage
      // transitions are implied by the lines around them.
      case 'capture-progress':
      case 'stage':
        break
    }
  }
}

/**
 * Ask only what this machine needs: an output folder, and an API key where
 * pages can't be read locally. There is deliberately no model question — on a
 * Mac that reads pages itself, a model would only be a way to start paying by
 * accident, so choosing OpenAI is left to `--model` or OCR_MODEL per run.
 */
export async function setup(): Promise<void> {
  const stored = await loadConfig()
  const localOcr = await isVisionOcrAvailable()

  console.log('Settings are stored in your home directory, so book-export')
  console.log('works from any folder. Press enter to keep a current value.\n')

  let openaiApiKey = stored.openaiApiKey
  if (localOcr) {
    console.log('This Mac reads page images by itself, free and offline, so')
    console.log('there is no account or key to set up.\n')
  } else {
    console.log('This computer cannot read page images by itself, so an OpenAI')
    console.log('API key is needed — reading a book usually costs well under a')
    console.log('dollar. Create one at https://platform.openai.com/api-keys\n')

    openaiApiKey =
      (await password({
        message: stored.openaiApiKey
          ? 'OpenAI API key (enter to keep existing):'
          : 'OpenAI API key:',
        mask: '*'
      })) || stored.openaiApiKey
  }

  const outDir = await input({
    message: 'Where should books be written?',
    default: stored.outDir ?? 'out'
  })

  const target = await saveConfig({
    ...stored,
    openaiApiKey: openaiApiKey || undefined,
    outDir: outDir.trim() || undefined
  })

  console.log(`\nSaved to ${target} (readable only by you).`)

  if (!openaiApiKey && !localOcr) {
    console.log('No API key stored — transcription will not work until one is.')
  }

  const wantsLogin = await confirm({
    message: 'Sign in to Amazon now?',
    default: true
  })
  if (wantsLogin) {
    await login(await applyConfig({ ...EMPTY_OPTIONS, command: 'login' }))
  }
}

async function clean(options: Options): Promise<void> {
  const asins = options.asins.length
    ? options.asins
    : await listBookDirs(options.outDir)

  if (!asins.length) {
    console.log(`No books found in ${options.outDir}`)
    return
  }

  let freed = 0
  for (const asin of asins) {
    // Under the same per-book lock as a run, because what this deletes is a
    // run's input: a transcription in progress still needs its page images,
    // and a capture in progress is still reading its render data.
    try {
      freed += await withBookLock(
        path.join(options.outDir, asin),
        () => cleanBook(asin, options),
        { command: 'clean' }
      )
    } catch (err) {
      if (!isBookBusyError(err)) throw err

      console.log(`[${asin}] skipped: ${err.message}`)
    }
  }

  console.log(`\nFreed ${formatBytes(freed)} in total.`)
}

/** Free what one book no longer needs; returns the bytes freed. */
async function cleanBook(asin: string, options: Options): Promise<number> {
  const render = await cleanRenderData(options.outDir, asin)

  // Page images only go when every captured page has text, otherwise a retry
  // silently becomes a re-capture. This is the same question the transcribe
  // stage asks before deleting them, asked the same way.
  let pages = { freed: 0, removed: [] as string[] }
  if (!options.keepPages) {
    const metadata = await readMetadata(options.outDir, asin)
    const completeness = bookCompleteness({
      metadata,
      content: await readContentStore(path.join(options.outDir, asin)),
      asin
    })

    if (completeness.capturedPages && !completeness.missingPages.length) {
      pages = await cleanPageImages(options.outDir, asin)
    } else if (completeness.transcribedPages) {
      console.log(`[${asin}] keeping page images: transcription is incomplete`)
    }
  }

  if (render.freed || pages.freed) {
    console.log(`[${asin}] freed ${formatBytes(render.freed + pages.freed)}`)
  }

  return render.freed + pages.freed
}

async function listBookDirs(outDir: string): Promise<string[]> {
  const entries = await fs
    .readdir(outDir, { withFileTypes: true })
    .catch(() => [])

  return entries
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'))
    .map((entry) => entry.name)
    .toSorted()
}

/** Open a browser so the user can sign in once; the session persists after. */
async function login(options: Options): Promise<void> {
  await fs.mkdir(options.profileDir, { recursive: true })
  console.log(`Opening a browser using profile ${options.profileDir}`)
  console.log(
    'Sign in to Amazon in the window that opens — it closes by itself once'
  )
  console.log("you're signed in.\n")

  const confirmed = await interactiveLogin(options.profileDir)

  if (confirmed) {
    console.log('Session saved. You can now run: book-export')
  } else {
    console.log(
      'Could not confirm the sign-in (the window was closed, or it timed out).'
    )
    console.log("If you did sign in, you're fine — try: book-export list")
  }
}

/** Read the library, always closing the browser afterwards. */
async function withLibrary(options: Options): Promise<LibraryBook[]> {
  const context = await launchBrowserContext({ profileDir: options.profileDir })

  try {
    return await fetchLibrary(context, { limit: options.limit })
  } finally {
    await context.close().catch(() => {})
    await context
      .browser()
      ?.close()
      .catch(() => {})
  }
}

function formatBookLine(book: LibraryBook): string {
  const authors = book.authors.length ? ` — ${book.authors.join(', ')}` : ''
  const progress =
    typeof book.percentageRead === 'number' && book.percentageRead > 0
      ? ` (${Math.round(book.percentageRead)}% read)`
      : ''

  return `${book.title}${authors}${progress}`
}

async function list(options: Options): Promise<void> {
  const books = await withLibrary(options)

  if (options.json) {
    console.log(JSON.stringify(books, null, 2))
    return
  }

  if (!books.length) {
    console.log('No books found in your Kindle library.')
    return
  }

  for (const book of books) {
    console.log(`${book.asin}  ${formatBookLine(book)}`)
  }

  console.log(`\n${books.length} book${books.length === 1 ? '' : 's'}`)
}

/** Let the user pick books from their library when they named none. */
async function selectFromLibrary(options: Options): Promise<string[]> {
  console.log('Reading your Kindle library…')
  const books = await withLibrary(options)

  if (!books.length) {
    console.log('No books found in your Kindle library.')
    return []
  }

  if (!process.stdin.isTTY) {
    console.error(
      'No ASINs given and no terminal to prompt on. Pass ASINs directly, or run: book-export list'
    )
    process.exitCode = 1
    return []
  }

  // A flat checkbox of a few hundred books is unusable, so offer to narrow it
  // down first. Empty input keeps everything.
  let shortlist = books
  if (books.length > FILTER_PROMPT_THRESHOLD) {
    const needle = (
      await input({
        message: `${books.length} books. Filter by title or author (blank for all):`
      })
    )
      .trim()
      .toLowerCase()

    if (needle) {
      shortlist = books.filter((book) =>
        `${book.title} ${book.authors.join(' ')}`.toLowerCase().includes(needle)
      )

      if (!shortlist.length) {
        console.log(`Nothing matched "${needle}".`)
        return []
      }
    }
  }

  return checkbox({
    message: `Select books to export (${shortlist.length} shown)`,
    pageSize: 15,
    choices: shortlist.map((book) => ({
      name: `${formatBookLine(book)}  [${book.asin}]`,
      value: book.asin
    }))
  })
}

async function main() {
  let options: Options | undefined
  try {
    options = parseArgs(process.argv.slice(2))
  } catch (err) {
    // Usage errors deserve a one-line message, not a stack trace.
    console.error(`book-export: ${(err as Error)?.message ?? err}`)
    console.error("Run 'book-export --help' for usage.")
    process.exitCode = 1
    return
  }

  if (!options) return

  if (options.command === 'setup') {
    await setup()
    return
  }

  options = await applyConfig(options)

  if (options.command === 'serve') {
    await startServer(options)
    return
  }

  if (options.command === 'clean') {
    await clean(options)
    return
  }

  if (options.command === 'login') {
    await login(options)
    return
  }

  if (options.command === 'list') {
    await list(options)
    return
  }

  if (!options.asins.length) {
    // Naming no book is a request to choose one, not a usage error — the whole
    // point is not having to look ASINs up by hand.
    options.asins = await selectFromLibrary(options)
    if (!options.asins.length) return
  }

  const failures: string[] = []
  for (const asin of options.asins) {
    try {
      const result = await processBook(asin, options, renderEvents(asin))

      // A book can be short of what was asked for without anything throwing:
      // a capture that stopped early, or pages with no text. Every command
      // decides that the same way, so `ocr` and `export` on their own report
      // it too instead of exiting 0 in silence.
      if (bookFellShort(result, options.command)) {
        incompleteBooks.add(asin)
      }

      if (options.command === 'all' || options.command === 'export') {
        console.log(
          `[${asin}] done in ${formatDuration(result.durationMs)}: ${result.outputs
            .map((file) => path.resolve(file))
            .join(', ')}`
        )
      }
    } catch (err) {
      failures.push(asin)
      console.error(`[${asin}] failed: ${(err as Error)?.message ?? err}`)
    }
  }

  if (failures.length) {
    console.error(`\n${failures.length} of ${options.asins.length} failed`)
  }

  if (incompleteBooks.size) {
    console.error(
      `${incompleteBooks.size} book(s) are missing part of the book: ${[...incompleteBooks].join(', ')}`
    )
  }

  // Incomplete output is not success, even though a file was written.
  if (failures.length || incompleteBooks.size) {
    process.exitCode = 1
  }
}

/**
 * Whether this module was launched directly, rather than imported.
 *
 * npm installs `bin` entries as symlinks, so the launched path and this
 * module's own path are different files on disk until both are resolved —
 * compare them raw and a globally installed `book-export` does nothing at
 * all. Anything unresolvable falls through to running: a CLI that runs when it
 * shouldn't is a test artefact, one that silently exits is a broken install.
 */
function isDirectEntryPoint(): boolean {
  const entry = process.argv[1]
  if (!entry) return false

  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return true
  }
}

if (isDirectEntryPoint()) {
  try {
    await main()
  } catch (err) {
    // A profile that's already in use is an everyday situation — the web app is
    // mid-capture in another window — not a crash. Say what to do about it
    // instead of printing a stack trace; everything else keeps its stack.
    if (!isProfileBusyError(err)) throw err

    console.error(`book-export: ${err.message}`)
    process.exitCode = 1
  }
}
