import { launchBrowserContext } from './extract-kindle-book'

/**
 * Interactive Amazon sign-in, shared by the CLI and the local web app.
 *
 * A browser window opens on the Kindle library; the person signs in by hand
 * (password, 2FA, whatever Amazon asks for) and we watch the URL until it
 * lands back on the library. That way the window can close itself on success
 * instead of asking the user to know when they're done.
 */

const LIBRARY_URL = 'https://read.amazon.com/kindle-library'

/** How long to wait for a person to complete sign-in by hand. */
const SIGN_IN_TIMEOUT_MS = 10 * 60 * 1000

const SIGN_IN_POLL_MS = 500

/**
 * How long a freshly loaded library page gets to redirect a signed-out
 * session. Amazon sends it to `/landing` by script after DOMContentLoaded, so
 * the URL at that moment still reads as the library. Same figure as the
 * native app's `redirectSettleNanoseconds`.
 */
const REDIRECT_SETTLE_MS = 1500

/**
 * Consecutive polls that must see a signed-in URL. One is not enough: the
 * reader domain shows up for a moment mid-flow (the library, before its
 * script redirects; a hop through read.amazon.com on the way back from
 * Amazon's form), and closing the window on that would end sign-in before it
 * happened. Matches the native app's `signedInPollsNeeded`.
 */
const SIGNED_IN_POLLS_NEEDED = 2

/**
 * Paths on read.amazon.com that mean nobody is signed in: the sign-in form,
 * any other step of Amazon's sign-in (`/ap/cvf` challenges, `/ap/mfa`), and
 * the landing page a session without cookies is sent to. The native app's
 * AmazonURLs uses the same rule; keep the two in step.
 */
export const SIGNED_OUT_PATH_REGEX =
  /^\/ap\/|\/ap\/signin|\/gp\/signin|^\/landing/

/**
 * Whether a URL shows a signed-in Kindle session.
 *
 * Amazon bounces an expired session from read.amazon.com to a signin page,
 * and a session with no Amazon cookies at all to `read.amazon.com/landing` —
 * the reader's own domain — so "on the reader domain, and on neither a signin
 * path nor the landing page" is the working definition, the same one the
 * library fetcher uses to throw NotSignedInError.
 */
export function isSignedInUrl(url: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return false
  }

  return (
    parsed.protocol === 'https:' &&
    parsed.hostname === 'read.amazon.com' &&
    !SIGNED_OUT_PATH_REGEX.test(parsed.pathname)
  )
}

/**
 * The parts of a Playwright page and browser context sign-in uses. Narrow on
 * purpose, so tests can drive the flow with a scripted stand-in.
 */
export interface SignInPage {
  url(): string
  goto(
    url: string,
    options: { waitUntil: 'domcontentloaded' }
  ): Promise<unknown>
  evaluate(script: string): Promise<unknown>
}

export interface SignInContext {
  pages(): SignInPage[]
  newPage(): Promise<SignInPage>
  on(event: 'close', listener: () => void): unknown
}

export interface WaitForSignInOptions {
  timeoutMs?: number
  pollMs?: number
  /** How long the first page load gets to redirect before it is judged. */
  settleMs?: number
}

const sleep = (ms: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms))

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
 * Press the signed-out landing page's "Sign in with your account" button,
 * which goes to Amazon's sign-in form and back to the library. Showing the
 * landing page instead would leave the person to work out that this button is
 * the step they are missing. The same script as NativeBackend's
 * `followLandingSignIn`; the text fallback covers a renamed id. `String.raw`
 * so the regex's `\s` reaches the page instead of collapsing to `s`.
 */
const FOLLOW_LANDING_SIGN_IN = String.raw`(() => {
  const button = document.querySelector('#top-sign-in-btn') ||
    Array.from(document.querySelectorAll('button, a, [role=button]'))
      .find((el) => /sign in with your account|^\s*sign in\s*$/i.test(el.textContent || ''));
  if (!button) return false;
  button.click();
  return true;
})()`

/**
 * Resolve `true` once a page in the context has shown a signed-in Kindle URL
 * for `SIGNED_IN_POLLS_NEEDED` polls in a row, `false` when the window is
 * closed or the timeout passes first.
 */
export async function waitForSignIn(
  context: SignInContext,
  {
    timeoutMs = SIGN_IN_TIMEOUT_MS,
    pollMs = SIGN_IN_POLL_MS
  }: WaitForSignInOptions = {}
): Promise<boolean> {
  let closed = false
  context.on('close', () => {
    closed = true
  })

  const deadline = Date.now() + timeoutMs
  let signedInPolls = 0
  while (!closed && Date.now() < deadline) {
    // The sign-in flow can navigate, open and close pages; look at whatever
    // exists right now rather than holding on to one page.
    let signedIn = false
    for (const page of context.pages()) {
      try {
        if (isSignedInUrl(page.url())) signedIn = true
      } catch {
        // The page closed under us mid-check; the next poll sees the rest.
      }
    }

    signedInPolls = signedIn ? signedInPolls + 1 : 0
    if (signedInPolls >= SIGNED_IN_POLLS_NEEDED) return true

    await sleep(pollMs)
  }

  return false
}

/**
 * Open the library in `context` and wait until the person is confirmed
 * signed in. Split from `interactiveLogin` so the flow can be tested without
 * a browser.
 */
export async function signInWithContext(
  context: SignInContext,
  opts: WaitForSignInOptions = {}
): Promise<boolean> {
  const { settleMs = REDIRECT_SETTLE_MS } = opts

  try {
    const page = context.pages()[0] ?? (await context.newPage())
    await page.goto(LIBRARY_URL, { waitUntil: 'domcontentloaded' })

    // A signed-out session is redirected by script after DOMContentLoaded;
    // judging the URL before that reads as "already signed in".
    await sleep(settleMs)

    if (isLandingUrl(page.url())) {
      // If the button is missing, the landing page stays up and its own
      // links still lead to sign-in; nothing is lost by carrying on.
      await page.evaluate(FOLLOW_LANDING_SIGN_IN).catch(() => {})
    }

    return await waitForSignIn(context, opts)
  } catch {
    // Navigation throws when the user closes the window mid-load; that's an
    // answer ("not confirmed"), not an error.
    return false
  }
}

/**
 * Open a browser window for the user to sign in to Amazon, and close it as
 * soon as the session is confirmed. Returns whether sign-in was confirmed —
 * `false` covers both "gave up" and "closed the window on us", so callers
 * should treat it as unknown rather than signed out.
 */
export async function interactiveLogin(
  profileDir: string,
  opts: WaitForSignInOptions = {}
): Promise<boolean> {
  const context = await launchBrowserContext({ profileDir })

  try {
    return await signInWithContext(context, opts)
  } finally {
    await context.close().catch(() => {})
    await context
      .browser()
      ?.close()
      .catch(() => {})
  }
}
