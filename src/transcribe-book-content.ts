import 'dotenv/config'

import fs from 'node:fs/promises'
import path from 'node:path'

import pMap from 'p-map'

import type { BookMetadata, ContentChunk } from './types'
import {
  createContentWriter,
  readContentStore,
  selectReusableChunks
} from './content-store'
import {
  type OcrEngine,
  type OcrPageText,
  OcrPageUnreadableError,
  OcrUnavailableError
} from './ocr-engine'
import { type ChatCompletionClient, createOpenAiOcrEngine } from './openai-ocr'
import { createTocLabelResolver, shapePageText } from './page-text'
import { assert, getEnv, readJsonFile, resolveScreenshotPath } from './utils'
import { createVisionOcrEngine, isVisionOcrAvailable } from './vision-ocr'

export type { ChatCompletionClient } from './openai-ocr'

const DEFAULT_REQUEST_TIMEOUT_MS = 120_000
const DEFAULT_CONCURRENCY = 16
const DEFAULT_MAX_RETRIES = 20
/** Attempts at an empty response before accepting the page really is blank. */
const EMPTY_RESPONSE_RETRIES = 3
const VERBOSE_LOGGING = getEnv('KINDLE_EXPORT_VERBOSE') === '1'

/**
 * Pick who reads the pages.
 *
 * Naming a model is an explicit request for OpenAI. Otherwise prefer local
 * OCR, which is free, offline and needs no API key — the single biggest
 * obstacle to someone using this without a developer's setup.
 */
export async function resolveOcrEngine(model?: string): Promise<OcrEngine> {
  if (!model && (await isVisionOcrAvailable())) {
    return createVisionOcrEngine()
  }

  return createOpenAiOcrEngine({ model })
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

async function withAbortTimeout<T>(
  timeoutMs: number,
  runSignal: AbortSignal,
  fn: (signal: AbortSignal) => Promise<T>
): Promise<T> {
  const controller = new AbortController()
  const abort = () => {
    controller.abort()
  }
  const timeout = setTimeout(abort, timeoutMs)
  // Stopping the run cancels the request in flight, rather than leaving it to
  // finish and be thrown away.
  runSignal.addEventListener('abort', abort, { once: true })
  if (runSignal.aborted) abort()

  try {
    return await fn(controller.signal)
  } finally {
    clearTimeout(timeout)
    runSignal.removeEventListener('abort', abort)
  }
}

/**
 * Whether a page's image can still be opened. Checked only once a read has
 * failed, so that an image which has gone missing fails its page at once
 * whichever engine tripped over it, instead of being retried twenty times.
 */
async function isImageReadable(imagePath: string): Promise<boolean> {
  return fs
    .access(imagePath, fs.constants.R_OK)
    .then(() => true)
    .catch(() => false)
}

export interface FailedPage {
  index: number
  page: number
  screenshot: string
  error: string
}

export interface TranscribeBookResult {
  content: ContentChunk[]
  /**
   * Pages that could not be read. Their text is simply absent from `content`,
   * so callers must surface this rather than treating the result as complete.
   */
  failedPages: FailedPage[]
}

export interface TranscribeBookOptions {
  asin: string
  /** Root directory holding one folder per ASIN. Defaults to `out`. */
  outDir?: string
  /**
   * OpenAI vision model to read pages with. Leave unset to use free local OCR
   * where it's available.
   */
  model?: string
  /** Abort a single page request after this long. */
  requestTimeoutMs?: number
  /** Page images read in parallel. */
  concurrency?: number
  /** Attempts per page before giving up on it. */
  maxRetries?: number
  /** Re-read every page, discarding text transcribed on a previous run. */
  force?: boolean
  /** Called as each page completes, for progress reporting. */
  onProgress?: (done: number, total: number) => void
  /** Injectable for tests; overrides engine selection entirely. */
  engine?: OcrEngine
  /** Injectable for tests; forces the OpenAI engine with a faked client. */
  client?: ChatCompletionClient
}

/**
 * Transcribe a book's captured page images to text.
 *
 * Pages already present in `content.json` are kept as-is unless `force` is set,
 * so re-running after a partial failure retries only the pages that failed
 * rather than paying to read the whole book again.
 */
export async function transcribeBook({
  asin,
  outDir: root = 'out',
  model,
  requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  concurrency = DEFAULT_CONCURRENCY,
  maxRetries = DEFAULT_MAX_RETRIES,
  force = false,
  onProgress,
  engine: injectedEngine,
  client
}: TranscribeBookOptions): Promise<TranscribeBookResult> {
  const outDir = path.join(root, asin)
  const metadata = await readJsonFile<BookMetadata>(
    path.join(outDir, 'metadata.json')
  )
  assert(metadata.pages?.length, 'no page screenshots found')
  assert(metadata.toc?.length, 'invalid book metadata: missing toc')

  const tocLabelFor = createTocLabelResolver(metadata)

  // const pageScreenshotsDir = path.join(outDir, 'pages')
  // const pageScreenshots = await globby(`${pageScreenshotsDir}/*.png`)
  // assert(pageScreenshots.length, 'no page screenshots found')

  // A faked client is a test asking for the OpenAI path specifically; anything
  // else goes through normal selection.
  const engine =
    injectedEngine ??
    (client
      ? createOpenAiOcrEngine({ model, client })
      : await resolveOcrEngine(model))
  // Only an engine we created is ours to shut down.
  const ownsEngine = !injectedEngine

  // Keep whatever a previous run managed to read, so a retry only pays for the
  // pages that actually failed — but only text that belongs to the pages on
  // disk right now. After a re-capture the old chunks line up by index and are
  // about entirely different pages.
  const existing = force
    ? []
    : selectReusableChunks(await readContentStore(outDir), metadata)
  const existingByIndex = new Map(
    existing.map((chunk) => [chunk.index, chunk] as const)
  )

  // Pages are saved as they finish rather than in one write at the end, so an
  // interrupted run keeps what it already paid for.
  const writer = createContentWriter(outDir, {
    captureId: metadata.captureId,
    chunks: existing
  })

  const pending = metadata.pages.filter(
    (pageChunk) => !existingByIndex.has(pageChunk.index)
  )
  // Page images are cleaned up once a book is fully transcribed, so a missing
  // one usually means "already done and tidied", not a broken install.
  if (pending.length) {
    const missing = await fs
      .access(resolveScreenshotPath(outDir, pending[0]!.screenshot))
      .then(() => false)
      .catch(() => true)

    assert(
      !missing,
      `page images for ${asin} are gone (cleaned up after transcription). ` +
        `Run 'kindle-export capture ${asin} --force-capture' to fetch them again.`
    )
  }

  const failedPages: FailedPage[] = []
  let completed = 0
  // Set when the engine says no page can be read at all (a rejected API key,
  // an unknown model). Every page in flight stops and nothing new starts:
  // without this, a bad key spent a quarter of an hour failing a book one
  // page and twenty retries at a time.
  let fatalError: OcrUnavailableError | undefined
  const run = new AbortController()

  await pMap(
    pending,
    async (pageChunk) => {
      const { screenshot, index, page } = pageChunk
      // Stored relative to the book directory; older captures stored something
      // else again, so never open `screenshot` directly.
      const imagePath = resolveScreenshotPath(outDir, screenshot)
      if (fatalError) return

      try {
        let retries = 0

        do {
          if (fatalError) return

          // Pinned per iteration: the retry counter is mutated below, and the
          // engine must see the attempt this call actually is.
          const attempt = retries
          let raw: OcrPageText
          try {
            raw = await withAbortTimeout(
              requestTimeoutMs,
              run.signal,
              (signal) => engine.recognize({ imagePath, attempt, signal })
            )
          } catch (err: any) {
            // Retrying these cannot help, so they go straight to the handlers
            // below rather than through the backoff.
            if (
              err instanceof OcrUnavailableError ||
              err instanceof OcrPageUnreadableError
            ) {
              throw err
            }
            if (fatalError) return
            if (!(await isImageReadable(imagePath))) {
              throw new OcrPageUnreadableError(
                `page image is missing or unreadable: ${imagePath}`,
                { cause: err }
              )
            }

            ++retries
            if (retries >= maxRetries) {
              throw err
            }

            console.warn('retrying OCR error...', {
              index,
              retries,
              screenshot: imagePath,
              error: err?.message ?? String(err)
            })
            const backoffMs = Math.min(2000, 200 * 2 ** retries)
            await sleep(backoffMs)
            continue
          }

          // Judged before the TOC label comes off: a chapter-opening page that
          // is nothing but its heading is a real read, not an empty response
          // worth retrying.
          const hasText = shapePageText(raw.text) !== ''

          ++retries

          // Nothing came back. Retry a couple of times in case the model just
          // hiccuped, then take it at its word: blank pages are ordinary in a
          // book, and an empty page is the honest transcription of one.
          // Failing it instead would mark the book permanently incomplete and
          // keep its page images from ever being cleaned up.
          if (
            !hasText &&
            retries < Math.min(EMPTY_RESPONSE_RETRIES, maxRetries)
          ) {
            await sleep(Math.min(2000, 200 * 2 ** retries))
            continue
          }

          if (!hasText) {
            console.warn('treating page as blank', {
              index,
              screenshot: imagePath
            })
          }

          // The same shaping the exporters redo from `lines`, so text stored
          // now and text rebuilt later only differ when the rules have.
          const text = shapePageText(raw.text, {
            tocLabelToStrip: tocLabelFor(pageChunk)
          })

          const result: ContentChunk = {
            index,
            page,
            text,
            screenshot,
            // The engine's own view of the page, when it has one: what `text`
            // was built from, kept so the building can be redone from disk.
            ...(raw.lines?.length ? { lines: raw.lines } : {})
          }
          if (VERBOSE_LOGGING) {
            console.log(result)
          }

          // Saved here rather than after the whole book: a page that has been
          // read is work that has been paid for, and Ctrl+C an hour in used to
          // throw all of it away.
          writer.add(result)
          onProgress?.(++completed, pending.length)

          return
        } while (true)
      } catch (err) {
        if (err instanceof OcrUnavailableError) {
          // Reported once for the whole run below, not as a failure of this
          // page: nothing was wrong with the page.
          if (!fatalError) {
            fatalError = err
            run.abort()
          }
          return
        }

        // Record rather than swallow: a dropped page leaves a hole in the
        // book, and the caller has to be able to tell that from success.
        const message = (err as Error)?.message ?? String(err)
        console.error(`error processing image ${index} (${imagePath})`, err)
        failedPages.push({ index, page, screenshot, error: message })
        onProgress?.(++completed, pending.length)
      }
    },
    { concurrency }
  ).finally(async () => {
    // Local OCR runs as a child process, which would otherwise outlive a
    // failed run and keep the command from exiting.
    if (ownsEngine) await engine.close()
  })

  // The last few pages are still inside the save debounce; this is what makes
  // the file on disk the whole book rather than nearly it. It runs before a
  // fatal error is thrown too, so the pages read before it are kept.
  await writer.flush()

  if (fatalError) throw fatalError

  return { content: writer.chunks(), failedPages }
}
