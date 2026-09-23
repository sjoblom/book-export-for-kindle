import 'dotenv/config'

import { createHash, randomUUID } from 'node:crypto'
import fs from 'node:fs/promises'
import path from 'node:path'

import type { SetRequired } from 'type-fest'
import delay from 'delay'
import pRace from 'p-race'
// import { chromium } from 'playwright'
import { chromium } from 'patchright'
import sharp from 'sharp'

import type {
  BookMetadata,
  CaptureStatus,
  CaptureStopReason,
  PageNav
} from './types'
import {
  inspectProfileLock,
  isProfileBusyError,
  ProfileBusyError
} from './browser-profile-lock'
import {
  chevronClickTimeoutMs,
  isOnLastNumberedPage,
  MAX_CAPTURE_RECOVERIES,
  maxNavigationAttempts,
  type NavigationResult,
  navigationResult,
  navigationTimeoutMs,
  resumeScreenDecision,
  type ResumeState,
  shouldRecover,
  shouldStopBeforeCapture,
  shouldStopCapture
} from './capture-termination'
import { parsePageNav } from './playwright-utils'
import {
  applyRenderFiles,
  applyStartReading,
  applyYjMetadata,
  emptyNav,
  finalizeBookNav,
  normalizePageNumber,
  pageForPosition
} from './render-metadata'
import { isSignedInUrl, SIGNED_OUT_PATH_REGEX } from './session'
import {
  assert,
  extractTar,
  getEnv,
  hashObject,
  normalizeBookMetadata,
  PAGE_IMAGES_DIR
} from './utils'

// Block amazon analytics requests
// (not strictly necessary, but adblockers do this by default anyway and it
// makes the script run a bit faster)
const urlRegexBlacklist = [
  /unagi-\w+\.amazon\.com/i, // 'unagi-na.amazon.com'
  /m\.media-amazon\.com.*\/showads/i,
  /fls-na\.amazon\.com.*\/remote-weblab-triggers/i
]

type RENDER_METHOD = 'screenshot' | 'blob'
const renderMethod: RENDER_METHOD = 'blob'

const deviceScaleFactor = 2
const VERBOSE_LOGGING = getEnv('KINDLE_EXPORT_VERBOSE') === '1'
const QUIET_LOGGING = getEnv('KINDLE_EXPORT_QUIET') === '1'

/**
 * Test hook: pretend the reader stalls once, on the first screen at or past
 * this page, so stall recovery can be exercised against the real reader —
 * genuine stalls are rare and can't be provoked on demand.
 */
const SIMULATE_STALL_AT_PAGE = Number.parseInt(
  getEnv('KINDLE_EXPORT_SIMULATE_STALL_AT_PAGE') ?? '',
  10
)

function logInfo(...args: any[]) {
  if (!QUIET_LOGGING) {
    console.log(...args)
  }
}

function warnInfo(...args: any[]) {
  if (!QUIET_LOGGING) {
    console.warn(...args)
  }
}

function logVerbose(...args: any[]) {
  if (VERBOSE_LOGGING) {
    console.log(...args)
  }
}

function warnVerbose(...args: any[]) {
  if (VERBOSE_LOGGING) {
    console.warn(...args)
  }
}

// Re-exported so callers that only know about `launchBrowserContext` can
// recognise its one expected failure without a second import.
export { isProfileBusyError, ProfileBusyError } from './browser-profile-lock'

export type BrowserContext = Awaited<
  ReturnType<typeof chromium.launchPersistentContext>
>

export type Page = Awaited<ReturnType<BrowserContext['newPage']>>

export interface LaunchBrowserOptions {
  profileDir?: string
  /**
   * Chrome release channel. Defaults to installed Google Chrome, falling back
   * to Playwright's bundled Chromium when Chrome isn't present — which is the
   * common case on Linux and in containers.
   */
  channel?: string
}

/** Playwright's message when the requested channel isn't installed. */
const MISSING_CHANNEL_REGEX =
  /channel .*(not (installed|found))|Executable doesn't exist|Chromium distribution/i

async function cleanupStaleSingletonLocks(profileDir: string) {
  for (const filename of [
    'SingletonLock',
    'SingletonCookie',
    'SingletonSocket'
  ]) {
    await fs.unlink(path.join(profileDir, filename)).catch(() => {})
  }
}

/**
 * Make sure nothing else is using the shared browser profile.
 *
 * A stale lock is cleared; a live owner is reported. This used to kill the pid
 * named in the lock, which meant a second command — `list`, `login`, another
 * `serve` — silently killed the browser the web app was capturing with, and a
 * recycled pid meant killing a process that had nothing to do with us.
 */
async function ensureBrowserProfileAvailable(profileDir: string) {
  const lockPath = path.join(profileDir, 'SingletonLock')
  const linkTarget = await fs.readlink(lockPath).catch(() => undefined)

  const lock = await inspectProfileLock({ profileDir, linkTarget })

  if (lock.state === 'unlocked') return

  if (lock.state === 'busy') {
    throw new ProfileBusyError(lock.pid, profileDir)
  }

  warnVerbose(`clearing a stale browser profile lock (${lock.reason})`)
  await cleanupStaleSingletonLocks(profileDir)
}

/**
 * Launch a persistent browser context with the shared profile directory.
 * The caller is responsible for closing the context when done.
 */
export async function launchBrowserContext(
  opts?: LaunchBrowserOptions
): Promise<BrowserContext> {
  const profileDir =
    opts?.profileDir?.trim() ||
    getEnv('BROWSER_PROFILE_DIR')?.trim() ||
    path.join('out', '.browser-profile')
  await fs.mkdir(profileDir, { recursive: true })

  let context: BrowserContext | undefined
  let channel: string | undefined =
    opts?.channel?.trim() || getEnv('BROWSER_CHANNEL')?.trim() || 'chrome'

  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await ensureBrowserProfileAvailable(profileDir)
      context = await chromium.launchPersistentContext(profileDir, {
        headless: false,
        ...(channel ? { channel } : {}),
        args: [
          // hide chrome's crash restore popup
          '--hide-crash-restore-bubble',
          // disable chrome's password autosave popups
          '--disable-features=PasswordAutosave',
          // disable chrome's passkey popups
          '--disable-features=WebAuthn',
          // disable chrome creating 1GB temp directories on each run
          '--disable-features=MacAppCodeSignClone',
          // keep a minimized/covered window rendering and firing timers —
          // without these, hiding the capture window stalls page turning
          '--disable-background-timer-throttling',
          '--disable-backgrounding-occluded-windows',
          '--disable-renderer-backgrounding'
        ],
        ignoreDefaultArgs: [
          // disable chrome's default automation detection flag
          '--enable-automation',
          // adding this cause chrome shows a weird admin popup without it
          '--no-sandbox',
          // adding this cause chrome shows a weird admin popup without it
          '--disable-blink-features=AutomationControlled'
        ],
        // bypass amazon's default content security policy which allows us to inject
        // our own scripts into the page
        bypassCSP: true,
        deviceScaleFactor,
        viewport: { width: 1280, height: 720 }
      })

      // Install the blob capture init script on the context so it runs on every
      // new page automatically.
      if (renderMethod === 'blob') {
        await context.addInitScript(() => {
          const origCreateObjectURL = URL.createObjectURL.bind(URL)
          URL.createObjectURL = function (blob: Blob) {
            const type = blob.type || 'application/octet-stream'
            const url = origCreateObjectURL(blob)
            // nodeLog('createObjectURL', url, type, blob.size)

            // Rendered pages are always images. Anything else (fonts, scripts,
            // JSON) can never become the main image's `src`, so copying it into
            // node would only cost CPU and memory for the whole capture.
            if (!type.startsWith('image/')) {
              return url
            }

            // Snapshot blob bytes immediately because kindle's renderer revokes
            // them immediately after they're used.
            ;(async () => {
              const buf = await blob.arrayBuffer()
              // store raw base64 (not data URL) to keep payload small
              let binary = ''
              const bytes = new Uint8Array(buf)
              for (const byte of bytes) {
                // eslint-disable-next-line unicorn/prefer-code-point
                binary += String.fromCharCode(byte)
              }

              const base64 = btoa(binary)

              // @ts-expect-error captureBlob
              captureBlob(url, { type, base64 })
            })()

            return url
          }
        })
      }

      return context
    } catch (err) {
      await context?.close().catch(() => {})

      // Someone else is legitimately using the profile. Retrying can't help,
      // and the retry warning would bury the one message worth reading.
      if (isProfileBusyError(err)) {
        throw err
      }

      // Google Chrome isn't installed (usual on Linux and in containers), so
      // fall back to the Chromium that ships with Playwright.
      if (
        channel &&
        MISSING_CHANNEL_REGEX.test((err as Error)?.message ?? '')
      ) {
        console.warn(
          `Google Chrome not found; falling back to bundled Chromium. Set BROWSER_CHANNEL to override.`
        )
        channel = undefined
        continue
      }

      if (attempt >= 3) {
        throw err
      }

      console.warn(
        `browser launch attempt ${attempt} failed, retrying with shared profile...`
      )
      await delay(1000)
    }
  }

  throw new Error('failed to initialize browser context')
}

async function setWindowState(
  page: Page,
  state: 'minimized' | 'normal'
): Promise<void> {
  const session = await page.context().newCDPSession(page)
  try {
    const { windowId } = await session.send('Browser.getWindowForTarget')
    await session.send('Browser.setWindowBounds', {
      windowId,
      bounds: { windowState: state }
    })
  } finally {
    await session.detach().catch(() => {})
  }
}

/**
 * Park the automation window in the Dock so it doesn't sit on top of whatever
 * the user is doing — left in front, it invites exactly the clicks and
 * closings that break a capture. Playwright drives the page over CDP rather
 * than OS events, and the launch args disable background throttling, so a
 * minimized window keeps turning pages.
 */
export async function hideBrowserWindow(page: Page): Promise<void> {
  try {
    await setWindowState(page, 'minimized')
  } catch {
    // Cosmetic — a window that stays visible is not a failure.
  }
}

/** Bring a hidden automation window back when the user is needed in it. */
export async function showBrowserWindow(page: Page): Promise<void> {
  try {
    await setWindowState(page, 'normal')
    await page.bringToFront()
  } catch {
    // The window is already visible at worst.
  }
}

export interface ExtractBookOptions {
  asin: string
  /** Root directory holding one folder per ASIN. Defaults to `out`. */
  outDir?: string
  /**
   * Minimize the automation window while capturing. It is brought back
   * automatically if Amazon asks for a sign-in.
   */
  hideWindow?: boolean
}

/** How long to wait for a person to complete sign-in by hand. */
const MANUAL_SIGN_IN_TIMEOUT_MS = 5 * 60 * 1000

/**
 * Whether a URL is one of Amazon's signed-out pages: its sign-in form, the
 * challenges that follow it (`/ap/cvf`, `/ap/mfa`, …), or the reader's own
 * signed-out landing page, where a session with no Amazon cookies is sent.
 *
 * The paths are session.ts's, so the capture and the sign-in window agree on
 * what "signed out" looks like; the host check keeps a book or library page
 * that happens to have such a path from counting.
 */
export function isSignedOutUrl(url: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return false
  }

  const onAmazon =
    parsed.hostname === 'amazon.com' || parsed.hostname.endsWith('.amazon.com')
  return (
    onAmazon &&
    (SIGNED_OUT_PATH_REGEX.test(parsed.pathname) ||
      parsed.pathname.startsWith('/ap/'))
  )
}

/** Whether a URL is the reader's signed-out landing page. */
function isLandingUrl(url: string): boolean {
  try {
    const parsed = new URL(url)
    return (
      parsed.hostname === 'read.amazon.com' &&
      parsed.pathname.startsWith('/landing')
    )
  } catch {
    return false
  }
}

/**
 * Extract a single Kindle book using the given browser context.
 * Creates a new page for the extraction and closes it when done.
 */
export async function extractBook(
  context: BrowserContext,
  opts: ExtractBookOptions
): Promise<void> {
  const { asin, hideWindow } = opts
  const asinL = asin.toLowerCase()

  const outDir = path.join(opts.outDir ?? 'out', asin)
  const bookDataDir = path.join(outDir, 'data')
  const pageScreenshotsDir = path.join(outDir, PAGE_IMAGES_DIR)
  const metadataPath = path.join(outDir, 'metadata.json')
  await fs.mkdir(bookDataDir, { recursive: true })
  await fs.mkdir(pageScreenshotsDir, { recursive: true })

  const krRendererMainImageSelector = '#kr-renderer .kg-full-page-img img'
  const nextPageChevronSelector = '.kr-chevron-container-right'
  const bookReaderUrl = `https://read.amazon.com/?asin=${asin}`

  const result: SetRequired<Partial<BookMetadata>, 'pages' | 'nav'> = {
    // Stamped before the first page is written, so every image this run
    // produces is tied to it. Anything transcribed from an earlier capture of
    // the same book carries a different id and can be recognised as stale.
    captureId: randomUUID(),
    pages: [],
    // locationMap: { locations: [], navigationUnit: [] },
    nav: emptyNav()
  }

  // Create a fresh page for this book extraction
  const page = await context.newPage()
  if (hideWindow) {
    await hideBrowserWindow(page)
  }

  try {
    // Kindle's "Most Recent Page Read" dialog appears when the book content
    // finishes loading — which races with everything else — and until it's
    // answered its overlay swallows every click, so an action just retries
    // until it times out. A locator handler is the reliable way to deal with
    // that: Playwright runs it whenever the dialog is in the way, whatever
    // else we happen to be doing. We always start from the beginning of the
    // book, so the answer is always No.
    await page.addLocatorHandler(
      page
        .locator('ion-alert, [role="dialog"], .alert-wrapper')
        .filter({ hasText: /most recent page read/i })
        .first(),
      async (dialog) => {
        warnInfo('dismissing "Most Recent Page Read" dialog')
        await dialog
          .locator('button, ion-button')
          .filter({ hasText: /^\s*no\s*$/i })
          .first()
          .click({ force: true })
          .catch(() => {})
      }
    )

    await page.route('**/*', async (route) => {
      const urlString = route.request().url()
      for (const regex of urlRegexBlacklist) {
        if (regex.test(urlString)) {
          return route.abort()
        }
      }

      return route.continue()
    })

    page.on('response', async (response) => {
      try {
        const status = response.status()
        if (status !== 200) {
          return
        }

        const url = new URL(response.url())
        if (url.pathname.endsWith('YJmetadata.jsonp')) {
          const body = await response.text()
          const meta = applyYjMetadata(result, body, asin)
          if (meta) {
            warnVerbose('book meta', meta)
          }
        } else if (
          url.hostname === 'read.amazon.com' &&
          url.searchParams.get('asin')?.toLowerCase() === asinL
        ) {
          if (url.pathname === '/service/mobile/reader/startReading') {
            const body: any = await response.json()
            if (applyStartReading(result, body)) {
              warnVerbose('book info', result.info)
            }
          } else if (url.pathname === '/renderer/render') {
            // TODO: these TAR files have some useful metadata that we could use...
            const params = Object.fromEntries(url.searchParams.entries())
            const hash = hashObject(params)
            const renderDir = path.join(bookDataDir, 'render', hash)
            await fs.mkdir(renderDir, { recursive: true })
            const body = await response.body()
            const tempDir = await extractTar(body, { cwd: renderDir })
            const { startingPosition, skipPageCount, numPage } = params
            logVerbose('RENDER TAR', tempDir, {
              startingPosition,
              skipPageCount,
              numPage
            })

            // The same interpretation the native app applies to the TAR it
            // intercepts, so both write the same metadata.json.
            const readRenderFile = (name: string) =>
              fs
                .readFile(path.join(renderDir, name), 'utf8')
                .catch(() => undefined)
            applyRenderFiles(
              result,
              {
                locationMap: await readRenderFile('location_map.json'),
                metadata: await readRenderFile('metadata.json'),
                toc: await readRenderFile('toc.json')
              },
              asin
            )

            // TODO: `page_data_0_5.json` has start/end/words for each page in this render batch
          }
        }
      } catch {}
    })

    // Only used for the 'blob' render method. Every image blob the page turns
    // into an object URL lands here, but only the one that becomes the main
    // image's `src` is ever consumed. The rest (pages rendered while walking to
    // a target page, neighbours Kindle prefetches, other images) would
    // otherwise pile up for the whole capture, so entries are aged out, see
    // `evictStaleBlobs`.
    const capturedBlobs = new Map<
      string,
      {
        type: string
        base64: string
        // How many blobs had been consumed when this one arrived.
        consumedAtArrival: number
      }
    >()
    let numBlobsConsumed = 0

    // Eviction is by age rather than by position relative to the consumed
    // blob. Blobs arrive in the order their bytes finish copying, not the order
    // Kindle created them, and Kindle may render a prefetched neighbour before
    // the page it is about to show, so "everything inserted before `src`" can
    // include the very next page. A blob that has sat through several page
    // captures without becoming `src`, though, belongs to a page that is
    // behind us (or was never a page), and a revisit makes Kindle create a
    // fresh object URL anyway because it revokes the old one after use.
    const maxBlobAgeInConsumptions = 8
    // Backstop for long stretches with no consumption at all, such as walking
    // hundreds of pages to reach the start of the book. The oldest entries go
    // first, so the newest ones (the prefetched pages we are about to show)
    // survive.
    const maxCapturedBlobs = 64

    function evictStaleBlobs() {
      for (const [url, blob] of capturedBlobs) {
        if (
          numBlobsConsumed - blob.consumedAtArrival >
          maxBlobAgeInConsumptions
        ) {
          capturedBlobs.delete(url)
        }
      }

      // Maps iterate in insertion order, so the first keys are the oldest.
      for (const url of capturedBlobs.keys()) {
        if (capturedBlobs.size <= maxCapturedBlobs) break
        capturedBlobs.delete(url)
      }
    }

    function takeCapturedBlob(url: string) {
      const blob = capturedBlobs.get(url)
      if (!blob) return

      capturedBlobs.delete(url)
      numBlobsConsumed++
      evictStaleBlobs()
      return blob
    }

    if (renderMethod === 'blob') {
      await page.exposeFunction('nodeLog', (...args: any[]) => {
        if (!QUIET_LOGGING) {
          console.error('[page]', ...args)
        }
      })

      await page.exposeBinding(
        'captureBlob',
        (_source, url: string, payload: { type: string; base64: string }) => {
          capturedBlobs.set(url, {
            ...payload,
            consumedAtArrival: numBlobsConsumed
          })
          evictStaleBlobs()
        }
      )
    }

    const onSignedOutPage = (url: URL) => isSignedOutUrl(url.href)

    /**
     * Load the book, and hand over to sign-in if Amazon wants one first —
     * both when the capture starts and when a stall recovery reloads the
     * reader, which is where an expired session shows up mid-book.
     */
    async function openReader(timeoutMs: number) {
      await Promise.any([
        page.goto(bookReaderUrl, { timeout: timeoutMs }),
        page.waitForURL(onSignedOutPage, { timeout: timeoutMs })
      ])

      // A session with no cookies can be sent on to the landing page by a
      // script after the load has finished, so the URL right after `goto`
      // proves nothing yet: wait for the reader or a signed-out page,
      // whichever shows up first.
      await Promise.any([
        page.waitForSelector(krRendererMainImageSelector, {
          timeout: timeoutMs
        }),
        page.waitForURL(onSignedOutPage, { timeout: timeoutMs })
      ]).catch(() => {})

      if (!isSignedOutUrl(page.url())) return

      await signIn()

      if (!page.url().includes(bookReaderUrl)) {
        await page.goto(bookReaderUrl, { timeout: timeoutMs })
      }
    }

    async function signIn() {
      // The landing page's "Sign in with your account" button leads to the
      // sign-in form. Pressing it for the person saves them working out that
      // it's the step they're missing.
      if (isLandingUrl(page.url())) {
        await page
          .locator('#top-sign-in-btn')
          .click({ timeout: 10_000 })
          .catch(() => {})
        await page
          .waitForURL((url) => !isLandingUrl(url.href), { timeout: 10_000 })
          .catch(() => {})
      }

      // Sign-in is always done by the person, in the browser window that's
      // already open: the app never handles an Amazon password, and whatever
      // challenge Amazon throws up is answered where Amazon asks it.
      logInfo(
        'Amazon needs you to sign in. Complete sign-in in the browser window...'
      )

      // A hidden window has to come back for this — the user can't sign in
      // to a window they can't see.
      await showBrowserWindow(page)

      // Back on the reader, not merely off the sign-in form: Amazon's
      // challenge pages (`/ap/cvf`, `/ap/mfa`) come after it and are still
      // part of signing in.
      await page.waitForURL((url) => isSignedInUrl(url.href), {
        timeout: MANUAL_SIGN_IN_TIMEOUT_MS
      })

      logInfo('Signed in.')
      if (hideWindow) {
        await hideBrowserWindow(page)
      }
    }

    await openReader(30_000)

    async function updateSettings() {
      await dismissReaderPopoverMenu()
      logInfo('Looking for Reader settings button')
      const settingsButton = page
        .locator(
          'ion-button[aria-label="Reader settings"], ' +
            'button[aria-label="Reader settings"]'
        )
        .first()
      await settingsButton.waitFor({ timeout: 30_000 })
      logInfo('Clicking Reader settings')
      await settingsButton.click()
      await delay(500)

      // Change font to Amazon Ember
      // My hypothesis is that this font will be easier for OCR to transcribe...
      // TODO: evaluate different fonts & settings
      logInfo('Changing font to Amazon Ember')
      await page.locator('#AmazonEmber').click()
      await delay(200)

      // Change layout to single column
      logInfo('Changing to single column layout')
      await page
        .locator('[role="radiogroup"][aria-label$=" columns"]', {
          hasText: 'Single Column'
        })
        .click()
      await delay(200)

      logInfo('Closing settings')
      // The sync dialog can surface while the settings panel is open, and it
      // swallows this click — leaving the panel covering the page image.
      await dismissPossibleAlert()
      await settingsButton.click()
      await delay(500)
      await dismissReaderPopoverMenu()
    }

    /**
     * Open the reader menu and click "Go to Page"/"Go to Location".
     *
     * The popover animates open and can be closed from under us by the "Most
     * Recent Page Read" dialog handler, so a single instant `isVisible` read
     * is a coin toss — it has to be awaited, and the whole open retried.
     */
    async function openGoToModal(): Promise<boolean> {
      await dismissPossibleAlert()
      await dismissReaderPopoverMenu()
      await page.locator('#reader-header').hover({ force: true })
      await delay(200)
      await page.locator('ion-button[aria-label="Reader menu"]').click()

      const goToPageItem = page.locator('ion-item[role="listitem"]', {
        hasText: 'Go to Page'
      })
      const goToLocationItem = page.locator('ion-item[role="listitem"]', {
        hasText: 'Go to Location'
      })

      await goToPageItem
        .or(goToLocationItem)
        .first()
        .waitFor({ timeout: 5000 })
        .catch(() => {})

      if (await goToPageItem.isVisible()) {
        await goToPageItem.click()
      } else if (await goToLocationItem.isVisible()) {
        await goToLocationItem.click()
      } else {
        await dismissReaderPopoverMenu()
        return false
      }

      return true
    }

    async function goToPage(pageNumber: number) {
      let opened = false
      for (let attempt = 0; attempt < 3 && !opened; attempt++) {
        opened = await openGoToModal()
      }
      if (!opened) {
        throw new Error(
          'Unable to find "Go to Page" or "Go to Location" menu item'
        )
      }

      const modalInput = page
        .locator(
          'ion-modal.go-to-modal.show-modal input[placeholder="page number"], ion-modal.go-to-modal.show-modal input[placeholder*="location" i], ion-modal input[placeholder="page number"], ion-modal input[placeholder*="location" i]'
        )
        .first()
      await modalInput.fill(`${pageNumber}`)
      // await page.locator('ion-modal button', { hasText: 'Go' }).click()
      const goButton = page
        .locator(
          'ion-modal.go-to-modal.show-modal ion-button[item-i-d="go-to-modal-go-button"], ion-modal ion-button[item-i-d="go-to-modal-go-button"], ion-modal button, ion-modal ion-button',
          { hasText: 'Go' }
        )
        .first()
      await goButton.click({ force: true }).catch(async () => {
        await page.keyboard.press('Enter')
      })
      await delay(1000)
      await dismissReaderPopoverMenu()

      // Same retry as the walk itself: reading the footer straight after the
      // modal closes can catch it mid-render, and a blank read here used to be
      // taken as "we arrived".
      const nextPageNav = await readPageNav()
      if (nextPageNav?.page !== pageNumber) {
        console.warn(
          `Go to page ${pageNumber} failed; footer reports ${JSON.stringify(nextPageNav)}; walking with chevrons...`
        )
        await dismissGoToModal()
        await walkToPage(pageNumber)
      }
    }

    async function dismissGoToModal() {
      const goToModal = page.locator('ion-modal.go-to-modal.show-modal')
      const maybeOpen = await goToModal.isVisible().catch(() => false)
      if (!maybeOpen) return

      await goToModal
        .locator('ion-button[item-i-d="go-to-modal-cancel-button"]')
        .click({ force: true })
        .catch(async () => {
          await page.keyboard.press('Escape').catch(() => {})
        })
      await delay(300)
    }

    /**
     * Read the footer nav, tolerating the moment after a page turn or a modal
     * close where it hasn't re-rendered yet. A single blank read used to be
     * fatal.
     */
    async function readPageNav(): Promise<PageNav | undefined> {
      for (let attempt = 0; attempt < 10; attempt++) {
        const pageNav = await getPageNav().catch(() => undefined)
        if (pageNav) return pageNav

        await delay(200)
      }
    }

    async function walkToPage(pageNumber: number) {
      let previousPage: number | undefined
      let stuck = 0

      for (let attempts = 0; attempts < 500; attempts++) {
        const pageNav = await readPageNav()
        if (!pageNav) {
          const footerText = await page
            .locator('ion-footer ion-title')
            .first()
            .textContent()
            .catch(() => undefined)

          throw new Error(
            `Unable to read current page while walking to ${pageNumber} ` +
              `(footer reads: ${JSON.stringify(footerText)})`
          )
        }

        // The footer reports a location rather than a page in front and back
        // matter, and for roman-numbered pages. Derive a page from it where the
        // location map allows, so walking can still tell which way to go.
        const currentPage =
          pageNav.page ??
          (pageNav.location === undefined
            ? undefined
            : pageForPosition(result.locationMap, pageNav.location))

        if (currentPage === pageNumber) return
        if (pageNumber === 1 && currentPage !== undefined && currentPage <= 1) {
          return
        }

        // With no page to compare against, assume we're ahead of the content
        // and walk forward — goToPage is only ever aimed at the start of the
        // book or back at where the reader began.
        const direction =
          currentPage !== undefined && currentPage > pageNumber
            ? 'left'
            : 'right'
        const chevronSelector =
          direction === 'left'
            ? '.kr-chevron-container-left'
            : '.kr-chevron-container-right'
        const arrowKey = direction === 'left' ? 'ArrowLeft' : 'ArrowRight'

        // A walk that stops moving has hit something. If the chevron in our
        // direction is gone, that something is the edge of the book — the
        // footer never reports the final spread of some books (it reads
        // "page 144 of 145" on the last screen), so a target one past the
        // last reported page is as reached as it will ever be. Kindle removes
        // the chevron mid-render sometimes, so require it missing on repeated
        // stalled reads before believing it.
        if (currentPage !== undefined && currentPage === previousPage) {
          stuck++
          const chevronMissing =
            (await page
              .locator(chevronSelector)
              .count()
              .catch(() => 1)) === 0
          if (chevronMissing && stuck >= 2) {
            warnInfo(
              `stopping walk at page ${currentPage}: no ${direction} chevron, ` +
                `so page ${pageNumber} is past the edge of the book`
            )
            return
          }

          if (stuck >= 5) {
            throw new Error(
              `Unable to walk to page ${pageNumber}; stuck at page ${currentPage}`
            )
          }
        } else {
          stuck = 0
        }
        previousPage = currentPage
        const src = await page
          .locator(krRendererMainImageSelector)
          .getAttribute('src')
          .catch(() => undefined)

        await page
          .locator(chevronSelector)
          .click({ timeout: 5000 })
          .catch(async () => {
            await page.keyboard.press(arrowKey)
          })

        await pRace<boolean | undefined>((signal) => [
          (async () => {
            while (!signal.aborted) {
              const nextPageNav = await getPageNav().catch(() => undefined)
              if (nextPageNav?.page && nextPageNav.page !== pageNav.page) {
                return true
              }

              const newSrc = await page
                .locator(krRendererMainImageSelector)
                .getAttribute('src')
                .catch(() => undefined)
              if (src && newSrc && newSrc !== src) {
                return true
              }

              await delay(50)
            }
          })(),
          delay(5000, { signal })
        ])
      }

      const pageNav = await getPageNav().catch(() => undefined)
      throw new Error(
        `Unable to walk to page ${pageNumber}; last page was ${pageNav?.page ?? 'unknown'}`
      )
    }

    /**
     * Whether the reader is still offering a next page.
     *
     * Kindle takes the right-hand chevron away at the end of the book, and can
     * leave it in place but disabled instead. Only ever consulted after a page
     * turn produced nothing, and anything unreadable counts as "still there":
     * a missing chevron is what declares a book finished, and being wrong that
     * way round truncates it silently.
     */
    async function hasUsableNextPageChevron(): Promise<boolean> {
      try {
        const chevron = page.locator(nextPageChevronSelector).first()
        if ((await chevron.count()) === 0) return false
        if (!(await chevron.isVisible())) return false

        const disabled = await chevron.evaluate(
          (el) =>
            el.hasAttribute('disabled') ||
            el.getAttribute('aria-disabled') === 'true' ||
            el.classList.contains('disabled') ||
            !!el.querySelector('[disabled], [aria-disabled="true"], .disabled')
        )

        return !disabled
      } catch {
        return true
      }
    }

    /**
     * The footer as it reads right now, allowing a moment for a re-render,
     * or `undefined`. Bounded, unlike `getPageNav`, whose `textContent` waits
     * out Playwright's default timeout when the footer isn't there at all —
     * which is exactly the case this is asked about.
     */
    async function readFooterNow() {
      for (let attempt = 0; attempt < 10; attempt++) {
        const text = await page
          .locator('ion-footer ion-title')
          .first()
          .textContent({ timeout: 200 })
          .catch(() => null)
        const nav = parsePageNav(text)
        if (nav) return nav
        await delay(200)
      }
    }

    async function getPageNav() {
      const footerText = await page
        .locator('ion-footer ion-title')
        .first()
        .textContent()
      return parsePageNav(footerText)
    }

    async function ensureFixedHeaderUI() {
      await page.locator('.top-chrome').evaluate((el) => {
        el.style.transition = 'none'
        el.style.transform = 'none'
      })
    }

    /**
     * Answer the "Most Recent Page Read" dialog.
     *
     * Kindle offers to jump to wherever you last read; we always want to start
     * from the beginning, so the answer is No. It appears once the book content
     * loads — not when the page first opens — and until it's gone every click
     * lands on its overlay, so this has to run after the reader is ready and
     * again before anything that navigates.
     */
    async function dismissPossibleAlert(): Promise<boolean> {
      const syncDialog = page
        .locator('ion-alert, [role="dialog"], .alert-wrapper')
        .filter({ hasText: /most recent page read/i })
        .first()

      if (await syncDialog.isVisible().catch(() => false)) {
        const $no = syncDialog
          .locator('button, ion-button')
          .filter({ hasText: /^\s*no\s*$/i })
          .first()

        if (await $no.isVisible().catch(() => false)) {
          warnInfo('dismissing "Most Recent Page Read" dialog')
          await $no.click({ force: true }).catch(() => {})
          await delay(300)
          return true
        }
      }

      // Any other yes/no alert sitting in the way.
      const $alertNo = page
        .locator('ion-alert button', { hasText: 'No' })
        .first()
      if (await $alertNo.isVisible().catch(() => false)) {
        await $alertNo.click({ force: true }).catch(() => {})
        await delay(300)
        return true
      }

      return false
    }

    async function dismissReaderPopoverMenu() {
      const readerPopover = page.locator('ion-popover')
      const maybeOpen = await readerPopover.isVisible().catch(() => false)
      if (!maybeOpen) {
        return
      }

      // Some Kindle popovers can get "stuck" and block all following clicks.
      // Try a few close strategies in order of lowest disruption.
      await page.keyboard.press('Escape').catch(() => {})
      await delay(150)
      await page.mouse.click(10, 10).catch(() => {})
      await delay(150)

      if (await readerPopover.isVisible().catch(() => false)) {
        await page
          .locator('ion-backdrop')
          .first()
          .click({ force: true })
          .catch(() => {})
        await delay(150)
      }
    }

    async function writeResultMetadata() {
      return fs.writeFile(
        metadataPath,
        JSON.stringify(normalizeBookMetadata(result), null, 2)
      )
    }

    // Wait for the book to render before touching the reader UI. The settings
    // panel used to be driven while the content was still loading, so the sync
    // dialog would appear mid-click and Playwright would retry against its
    // overlay until the action timed out.
    logInfo('Waiting for book reader to load...')
    await page
      .waitForSelector(krRendererMainImageSelector, { timeout: 60_000 })
      .catch(() => {
        console.warn(
          'Main reader content may not have loaded, continuing anyway...'
        )
      })

    await dismissPossibleAlert()
    await ensureFixedHeaderUI()
    await updateSettings()

    // Record the initial page navigation so we can reset back to it later
    const initialPageNav = await getPageNav()

    // At this point, we should have recorded all the base book metadata from the
    // initial network requests.
    const { usedFallbackToc } = finalizeBookNav(result)
    if (usedFallbackToc) {
      console.warn(
        'book toc was not initialized from render responses; synthesizing fallback toc item'
      )
    }
    const pageNumberPaddingAmount = `${result.nav.totalNumContentPages * 2}`
      .length

    // Recorded before the first page is captured and mutated in place, so the
    // metadata written after every page says "incomplete" until the loop
    // reaches an actual end. A run killed halfway through then reads as what it
    // is, rather than as a short book.
    const capture: CaptureStatus = {
      complete: false,
      reason: 'interrupted',
      lastPage: 0,
      totalContentPages: result.nav.totalNumContentPages
    }
    result.capture = capture
    await writeResultMetadata()

    // Every screen saved so far, by a hash of its image. Only consulted while
    // resuming after a recovery, to recognise the screens that come round
    // again; see `resumeScreenDecision`. A few thousand short strings at most.
    const capturedScreenHashes = new Set<string>()
    // Set while a recovery is walking back up to where the capture stalled.
    let resume: ResumeState | undefined

    /**
     * Load the reader afresh and put it back on `pageNumber`.
     *
     * Everything the capture relies on survives a navigation — the blob hook
     * is a context init script that runs on every document, the `captureBlob`
     * binding and the dialog handler belong to the page, and minimizing is a
     * window state a navigation doesn't touch — so this only has to redo what
     * the first load did to the document itself.
     */
    async function reloadReaderAt(pageNumber: number) {
      // Object URLs die with the document that made them, so nothing captured
      // from the old one can ever be `src` again. Waiting for them to age out
      // would only crowd the new reader's blobs toward the size backstop.
      capturedBlobs.clear()

      // Through sign-in if need be: a session that expired mid-book is one of
      // the ways the reader goes away.
      await openReader(60_000)
      await page.waitForSelector(krRendererMainImageSelector, {
        timeout: 60_000
      })
      await dismissPossibleAlert()
      await ensureFixedHeaderUI()
      // Font and layout are saved to the account and should survive the
      // reload, but screens are only recognised as already captured if they
      // render identically, and a reader that quietly came back in its
      // default font would turn every one of them into a duplicate. Both
      // clicks select what is already selected, so re-applying is cheap.
      await updateSettings()
      await goToPage(pageNumber)
    }

    /**
     * Answer a stop the capture loop arrived at: reload the reader and carry on
     * if it's a stall worth recovering from, otherwise record it as the end of
     * the capture. Returns whether to carry on.
     *
     * Every attempt is written to the metadata before it's made, so a run that
     * dies mid-recovery, or gives up after one, still says what happened.
     */
    async function recoverOrStop(stop: {
      complete: boolean
      reason: CaptureStopReason
    }): Promise<boolean> {
      for (;;) {
        const decision = shouldRecover({
          reason: stop.reason,
          page: capture.lastPage,
          recoveries: capture.recoveries ?? []
        })

        if (decision.type === 'give-up') {
          if (decision.why !== 'not-a-stall') {
            warnInfo(
              decision.why === 'recovery-limit'
                ? `not reloading the reader again: already recovered ${MAX_CAPTURE_RECOVERIES} times`
                : `not reloading the reader again: it has stalled at page ${capture.lastPage} after reloading`
            )
          }

          capture.complete = stop.complete
          capture.reason = stop.reason
          return false
        }

        const recoveries = (capture.recoveries ??= [])
        recoveries.push({
          reason: stop.reason,
          page: capture.lastPage,
          screens: result.pages.length
        })
        await writeResultMetadata()

        // Before anything was captured there is no "last page" to go back to,
        // only the start of the book.
        const resumePage =
          capture.lastPage > 0 ? capture.lastPage : result.nav.startContentPage
        warnInfo(
          `the reader stopped responding (${stop.reason}) after page ` +
            `${capture.lastPage}; reloading it and resuming from page ` +
            `${resumePage} (recovery ${recoveries.length} of ` +
            `${MAX_CAPTURE_RECOVERIES})...`
        )

        try {
          await reloadReaderAt(resumePage)
          resume = { page: resumePage, skipped: 0 }
          return true
        } catch (err: any) {
          // Counted all the same, so a reader that can't be reloaded at all
          // runs out of attempts instead of looping.
          warnInfo(`reloading the reader failed: ${err?.message ?? err}`)
        }
      }
    }

    // Navigate to the first content page of the book
    await goToPage(result.nav.startContentPage)

    let done = false
    let simulatedStallDone = false
    warnInfo(
      `\nreading ${result.nav.totalNumContentPages} content pages out of ${result.nav.totalNumPages} total pages...\n`
    )

    // Loop through each page of the book
    do {
      const pageNav = await getPageNav()
      const index = result.pages.length
      const currentNavPage = normalizePageNumber(
        pageNav,
        result.locationMap,
        index + 1
      )
      const footerCurrentValue = pageNav?.page ?? pageNav?.location

      const stopBeforeCapture = shouldStopBeforeCapture({
        hasPageNav: !!pageNav,
        currentPage: currentNavPage,
        totalContentPages: result.nav.totalNumContentPages
      })

      if (stopBeforeCapture) {
        if (stopBeforeCapture.reason === 'no-page-nav') {
          console.warn('lost track of the page position', { index })
        }

        if (await recoverOrStop(stopBeforeCapture)) continue
        break
      }

      assert(pageNav, 'expected a page nav after the pre-capture check')

      const src = (await page
        .locator(krRendererMainImageSelector)
        .getAttribute('src'))!

      let renderedPageImageBuffer: Buffer | undefined

      if (renderMethod === 'blob') {
        const blob = await pRace<{ type: string; base64: string } | undefined>(
          (signal) => [
            (async () => {
              while (!signal.aborted) {
                const blob = takeCapturedBlob(src)

                if (blob) {
                  return blob
                }

                await delay(1)
              }
            })(),

            delay(10_000, { signal })
          ]
        )

        assert(
          blob,
          `no blob found for src: ${src} (index ${index}; page ${currentNavPage})`
        )

        const rawRenderedImage = Buffer.from(blob.base64, 'base64')
        const c = sharp(rawRenderedImage)
        const m = await c.metadata()
        renderedPageImageBuffer = await c
          .resize({
            width: Math.floor(m.width! / deviceScaleFactor),
            height: Math.floor(m.height! / deviceScaleFactor)
          })
          .png({ quality: 90 })
          .toBuffer()
      } else {
        renderedPageImageBuffer = await page
          .locator(krRendererMainImageSelector)
          .screenshot({ type: 'png', scale: 'css' })
      }

      assert(
        renderedPageImageBuffer,
        `no buffer found for src: ${src} (index ${index}; page ${currentNavPage})`
      )

      const screenHash = createHash('sha256')
        .update(renderedPageImageBuffer)
        .digest('hex')

      let skipScreen = false
      if (resume) {
        const decision = resumeScreenDecision({
          resume,
          alreadyCaptured: capturedScreenHashes.has(screenHash),
          currentPage: currentNavPage,
          capturedAny: result.pages.length > 0
        })

        if (decision.type === 'lost-place') {
          warnInfo(
            `after reloading, the reader showed page ${currentNavPage} ` +
              `instead of page ${resume.page}; screens in between may be missing`
          )
          resume = undefined
          // The same stall again, as far as the budget is concerned: this
          // recovery didn't put the capture back where it was.
          const stalled = capture.recoveries?.at(-1)?.reason
          assert(stalled, 'expected a recorded recovery while resuming')
          if (await recoverOrStop({ complete: false, reason: stalled })) {
            continue
          }
          break
        }

        if (decision.type === 'skip') {
          resume.skipped++
          skipScreen = true
          logVerbose(
            `skipping a screen of page ${currentNavPage} captured before the reload`
          )
        } else {
          if (decision.possibleDuplicates) {
            warnInfo(
              `after reloading, page ${currentNavPage} rendered differently ` +
                'from before, so some of its screens may be captured twice'
            )
          } else {
            warnInfo(
              `resumed capturing after the reload at page ${currentNavPage} ` +
                `(${resume.skipped} screens already captured were skipped)`
            )
          }
          resume = undefined
        }
      }

      // Screens that come round again after a recovery are passed over
      // without writing anything, but still turned past below.
      if (!skipScreen) {
        // Recorded relative to the book directory rather than as the path this
        // process happens to write to: the tree can then be moved, and a later
        // stage run from a different working directory still finds the image.
        const screenshot = path.join(
          PAGE_IMAGES_DIR,
          `${index}`.padStart(pageNumberPaddingAmount, '0') +
            '-' +
            `${currentNavPage}`.padStart(pageNumberPaddingAmount, '0') +
            '.png'
        )

        await fs.writeFile(
          path.join(outDir, screenshot),
          renderedPageImageBuffer
        )
        const pageChunk = {
          index,
          page: currentNavPage,
          screenshot
        }
        result.pages.push(pageChunk)
        capture.lastPage = currentNavPage
        if (VERBOSE_LOGGING) {
          console.warn(pageChunk)
        } else if (!QUIET_LOGGING && (index === 0 || (index + 1) % 100 === 0)) {
          console.warn(
            `captured ${index + 1} page images; current page/location ${currentNavPage}`
          )
        }
        await writeResultMetadata()
        capturedScreenHashes.add(screenHash)
      }

      // The footer reaching the last page means "this is probably the last
      // screen", not "stop now": Kindle's page numbers are coarse, so the last
      // numbered page can span several rendered screens and the first of them
      // reads exactly like the last. Turning the page is the only thing that
      // tells them apart, so we always try — the footer only decides how long
      // to spend on the attempt.
      const onLastNumberedPage = isOnLastNumberedPage({
        value: footerCurrentValue,
        total: pageNav.total
      })
      const maxAttempts = maxNavigationAttempts(onLastNumberedPage)
      // Every attempt's outcome for this screen: the decision needs the run
      // of them, not the latest one.
      const observations: NavigationResult[] = []

      for (;;) {
        // This delay seems to help speed up the navigation process, possibly due
        // to the navigation chevron needing time to settle.
        await delay(100)

        let clickFailed = false
        try {
          // await page.keyboard.press('ArrowRight')
          await page
            .locator(nextPageChevronSelector)
            .click({ timeout: chevronClickTimeoutMs(onLastNumberedPage) })
        } catch (err: any) {
          // Expected at the end of the book, where there's no chevron to click.
          if (onLastNumberedPage) {
            logVerbose('no next page button on the final page', err.message)
          } else {
            console.warn(
              'unable to click next page button',
              err.message,
              pageNav
            )
          }

          clickFailed = true
        }

        const navigatedToNextPage = await pRace<boolean | undefined>(
          (signal) => [
            (async () => {
              while (!signal.aborted) {
                const newSrc = await page
                  .locator(krRendererMainImageSelector)
                  .getAttribute('src')

                if (newSrc && newSrc !== src) {
                  // src changes are the most reliable indicator that Kindle moved
                  // to another rendered page image.
                  return true
                }

                await delay(10)
              }

              return false
            })(),

            delay(navigationTimeoutMs({ onLastNumberedPage, clickFailed }), {
              signal
            })
          ]
        )

        if (currentNavPage >= SIMULATE_STALL_AT_PAGE && !simulatedStallDone) {
          warnInfo(`simulating a reader stall at page ${currentNavPage}`)
          observations.push(
            ...Array.from({ length: maxAttempts }, () => 'stalled' as const)
          )
          simulatedStallDone = true
        } else if (navigatedToNextPage) {
          observations.push('navigated')
        } else {
          // A missing chevron only means "last screen" if the reader is still
          // there to have one; the footer is read again now, since the one
          // from before the turn says nothing about a reader that has gone.
          const url = page.url()
          const signedOut = isSignedOutUrl(url)
          observations.push(
            navigationResult({
              navigated: false,
              signedOut,
              pageImage:
                !signedOut &&
                (await page
                  .locator(krRendererMainImageSelector)
                  .count()
                  .catch(() => 0)) > 0,
              footerReadable: !signedOut && !!(await readFooterNow()),
              nextPageUsable: !signedOut && (await hasUsableNextPageChevron())
            })
          )
          if (observations.at(-1) === 'signed-out') {
            warnInfo(`Amazon signed the reader out mid-book (${url})`)
          } else if (observations.at(-1) === 'reader-lost') {
            warnInfo('the reader is no longer showing the book')
          }
        }
        const action = shouldStopCapture({
          observations,
          onLastNumberedPage,
          maxAttempts
        })

        if (action.type === 'capture-next-screen') break
        if (action.type === 'retry-navigation') continue

        if (action.reason === 'end-of-book') {
          warnInfo('reached the end of the book', pageNav)
        } else {
          console.warn('unable to navigate to next page', pageNav)
        }

        // A recovery leaves the reader on a screen that hasn't been looked at
        // yet, so going round the outer loop again captures (or recognises)
        // it like any other.
        if (!(await recoverOrStop(action))) done = true
        break
      }
    } while (!done)

    await writeResultMetadata()
    if (!capture.complete) {
      console.warn(
        `capture stopped early at page ${capture.lastPage} of ${capture.totalContentPages} (${capture.reason})`
      )
    }
    logInfo()
    logInfo(metadataPath)

    if (initialPageNav?.page !== undefined) {
      warnInfo(`resetting back to initial page ${initialPageNav.page}...`)
      // Restoring the reading position is a courtesy: the capture is already
      // complete and on disk, so nothing that goes wrong here is allowed to
      // fail the run.
      await goToPage(initialPageNav.page).catch((err: Error) => {
        warnInfo(`could not restore the reading position: ${err.message}`)
      })
    }
  } finally {
    // Close only this page, not the whole browser context
    await page.close()
  }
}

export interface RunExtractionOptions extends ExtractBookOptions {
  /** Persistent browser profile holding the signed-in Amazon session. */
  profileDir?: string
}

/**
 * Capture a book's pages, owning the browser lifecycle.
 *
 * The stage functions take a context so several books can share one browser;
 * this wrapper is for callers extracting a single book.
 */
export async function runExtraction({
  profileDir,
  ...options
}: RunExtractionOptions): Promise<void> {
  const context = await launchBrowserContext({ profileDir })

  // Close the default blank page that comes with the persistent context
  for (const p of context.pages()) {
    await p.close()
  }

  try {
    await extractBook(context, options)
  } finally {
    await context.close()
    await context.browser()?.close()
  }
}
