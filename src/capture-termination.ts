import type { CaptureStopReason } from './types'

/**
 * Deciding when a page capture has actually reached the end of the book.
 *
 * Kindle's page numbers are coarse: one numbered page routinely spans several
 * rendered screens, which is exactly why the capture keeps its own screenshot
 * index alongside the footer's page number. That makes the footer a hint about
 * where we are and never proof that there is nothing left to render — the only
 * proof is asking the reader to turn the page and being refused.
 *
 * This lives apart from the browser driving because it's the part that fails
 * silently: stopping one screen early still writes a metadata file that says
 * the book finished, and nothing downstream can tell the difference.
 */

/** What a single page-turn attempt produced. */
export type NavigationResult =
  /** A different page image rendered — the reader moved. */
  | 'navigated'
  /** Nothing rendered, and the reader offers no next-page control. */
  | 'no-next-page'
  /** Nothing rendered, but a next-page control is still sitting there. */
  | 'stalled'
  /**
   * Nothing rendered, and the reader itself is gone or unreadable: no page
   * image, or no footer to read. A missing chevron means nothing here — every
   * control is missing when the reader is.
   */
  | 'reader-lost'
  /** The document went to Amazon's sign-in (or signed-out landing) page. */
  | 'signed-out'

/** What the capture could see after a page turn that rendered nothing new. */
export interface NavigationEvidence {
  /** Whether a different page image rendered. */
  navigated: boolean
  /** Whether the document is on a signed-out Amazon page. */
  signedOut: boolean
  /** Whether the reader's main page image is in the document now. */
  pageImage: boolean
  /** Whether the footer can be read now — not the reading from before the turn. */
  footerReadable: boolean
  /** Whether a visible, enabled next-page control is there. */
  nextPageUsable: boolean
}

/**
 * Classify one page-turn attempt.
 *
 * "No next-page control" is the one sign of an ending, so it only counts as
 * one while the reader is demonstrably still there. When the session expires
 * mid-book the document goes to a sign-in page, and a reader that crashed or
 * half-unloaded has no controls either; both lack a chevron exactly as the
 * last screen of a book does, and treating them the same would record a
 * capture that lost the reader at page 10 of 100 as a finished book.
 */
export function navigationResult({
  navigated,
  signedOut,
  pageImage,
  footerReadable,
  nextPageUsable
}: NavigationEvidence): NavigationResult {
  if (navigated) return 'navigated'
  if (signedOut) return 'signed-out'
  if (!pageImage || !footerReadable) return 'reader-lost'
  return nextPageUsable ? 'stalled' : 'no-next-page'
}

/** What the capture loop should do next. */
export type CaptureAction =
  | { type: 'capture-next-screen' }
  | { type: 'retry-navigation' }
  | { type: 'stop'; complete: boolean; reason: CaptureStopReason }

/** Turn attempts allowed for an ordinary screen before giving up on it. */
export const NAVIGATION_ATTEMPTS = 5

/**
 * Consecutive sightings of "no next page" it takes to believe the book ended.
 *
 * Two, because the one positive sign of an ending — the chevron being gone —
 * is also what the reader looks like for a moment mid-render. Seeing it gone
 * twice in a row, a few seconds apart, is the confirmation; seeing it once
 * is not, and a usable chevron in between starts the count again. The cost is
 * a few seconds on every finished capture, which is the price of not
 * declaring a book complete on a hunch.
 */
export const END_CONFIRMATION_ATTEMPTS = 2

/**
 * Turn attempts allowed on the last numbered page before giving up on it.
 *
 * One more than the confirmation needs, so a single stalled render before the
 * chevron disappears doesn't cost the confirmation its chance. Anything that
 * hasn't confirmed itself by then is recorded as unconfirmed, not finished.
 */
export const END_CONFIRMATION_MAX_ATTEMPTS = END_CONFIRMATION_ATTEMPTS + 1

/** How long a normal page turn is given to render a new image. */
export const NAVIGATION_TIMEOUT_MS = 10_000

/**
 * How long the end-of-book confirmation turn is given.
 *
 * Short on purpose. A real page turn renders in well under a second — the
 * previous screen's image blob has already arrived by the time we get here —
 * so this only has to outlast a slow render, not a stuck reader.
 */
export const END_CONFIRMATION_TIMEOUT_MS = 3000

/** How long to wait after the chevron click itself failed. */
export const CLICK_FAILED_TIMEOUT_MS = 1000

/** How long to spend trying to click the next-page chevron. */
export const NAVIGATION_CLICK_TIMEOUT_MS = 5000

/**
 * The same, while confirming the end of the book.
 *
 * There is usually no chevron left to click there, so this timeout is spent in
 * full on every finished capture — it buys nothing to make it generous.
 */
export const END_CONFIRMATION_CLICK_TIMEOUT_MS = 2000

export interface FooterPosition {
  /** The page (or location) the footer reports, when it reports one. */
  value?: number
  /** The total the footer reports, which is 0 or negative when unknown. */
  total: number
}

/**
 * Whether the footer says we're on the book's last numbered page.
 *
 * "Last numbered page" is not "last screen" — see the module comment — so this
 * only decides how hard to try turning the page, never whether to stop.
 */
export function isOnLastNumberedPage({
  value,
  total
}: FooterPosition): boolean {
  if (value === undefined) return false
  if (!(total > 0)) return false

  return value >= total
}

/** Attempts to allow for one screen. */
export function maxNavigationAttempts(onLastNumberedPage: boolean): number {
  return onLastNumberedPage
    ? END_CONFIRMATION_MAX_ATTEMPTS
    : NAVIGATION_ATTEMPTS
}

/** How long to spend on the chevron click itself. */
export function chevronClickTimeoutMs(onLastNumberedPage: boolean): number {
  return onLastNumberedPage
    ? END_CONFIRMATION_CLICK_TIMEOUT_MS
    : NAVIGATION_CLICK_TIMEOUT_MS
}

/** How long to wait for a new page image after clicking the chevron. */
export function navigationTimeoutMs({
  onLastNumberedPage,
  clickFailed
}: {
  onLastNumberedPage: boolean
  clickFailed: boolean
}): number {
  if (clickFailed) return CLICK_FAILED_TIMEOUT_MS

  return onLastNumberedPage
    ? END_CONFIRMATION_TIMEOUT_MS
    : NAVIGATION_TIMEOUT_MS
}

export interface BeforeCaptureInput {
  /** Whether the footer could be read at all. */
  hasPageNav: boolean
  /** The page number this screen belongs to. */
  currentPage: number
  /** The last page counted as content; past it is back matter. */
  totalContentPages: number
}

/**
 * Whether to stop before screenshotting the current screen.
 *
 * The page-number check is safe to act on immediately, unlike the footer's
 * "last page" (which the end-of-book decision has to confirm): it fires only
 * once the number has *strictly passed* the last content page, so every screen
 * belonging to that last page has already been captured. A page number in the
 * back matter is a statement about different content, not a coarse boundary we
 * might be standing on.
 */
export function shouldStopBeforeCapture({
  hasPageNav,
  currentPage,
  totalContentPages
}: BeforeCaptureInput): Extract<CaptureAction, { type: 'stop' }> | undefined {
  if (!hasPageNav) {
    // Losing the position mid-book is not an ending; we simply can't tell
    // where we are any more, so the capture is short and says so.
    return { type: 'stop', complete: false, reason: 'no-page-nav' }
  }

  if (totalContentPages > 0 && currentPage > totalContentPages) {
    return { type: 'stop', complete: true, reason: 'past-last-content-page' }
  }
}

export interface NavigationAttemptInput {
  /**
   * What every turn attempt on this screen produced so far, oldest first.
   * The whole history, not just the latest: the end of a book is a pattern
   * of observations, and one sighting proves nothing on its own.
   */
  observations: NavigationResult[]
  /** Whether the footer reported the book's last page for this screen. */
  onLastNumberedPage: boolean
  /** Attempts allowed for this screen, from `maxNavigationAttempts`. */
  maxAttempts: number
}

/** How many of the latest observations in a row found no next page. */
function trailingAbsences(observations: NavigationResult[]): number {
  let count = 0
  for (let i = observations.length - 1; i >= 0; i--) {
    if (observations[i] !== 'no-next-page') break
    count++
  }

  return count
}

/**
 * Decide what to do after one page-turn attempt.
 *
 * A successful turn always means "keep capturing", even on the last numbered
 * page — that's the whole point: a last page spanning several screens turns
 * normally, and each of those screens gets captured.
 *
 * Only one thing marks a capture complete: the reader offering no next page,
 * seen `END_CONFIRMATION_ATTEMPTS` times in a row, with no usable control
 * sighted in between. The reader drops the chevron for a moment mid-render,
 * so one absence — even as the final attempt of the budget — is not an
 * ending, and an absence followed by a usable control was the render, not
 * the end. Mid-book, where the footer gives no reason to expect an ending,
 * the run-out of the whole budget is required as well.
 *
 * A reader that still shows a usable next-page control and won't turn to it
 * is a reader that has stopped responding, wherever the footer says we are —
 * the footer counts pages, not screens, so it cannot vouch for the screens
 * after this one. That case is recorded as incomplete, and the person can
 * capture again, rather than as a finished book that is quietly short.
 *
 * A reader that has gone (`reader-lost`) is retried like a stall — it may be
 * a moment mid-render — and breaks any run of absences, so it can never add
 * up to an ending. A sign-in page (`signed-out`) stops at once, as a stall.
 */
export function shouldStopCapture({
  observations,
  onLastNumberedPage,
  maxAttempts
}: NavigationAttemptInput): CaptureAction {
  const latest = observations.at(-1)
  if (latest === 'navigated') {
    return { type: 'capture-next-screen' }
  }

  // Retrying page turns on a sign-in page can't succeed; stopping as a stall
  // hands the capture to the recovery, whose reload routes it to sign-in.
  if (latest === 'signed-out') {
    return { type: 'stop', complete: false, reason: 'navigation-failed' }
  }

  const confirmedAbsent =
    trailingAbsences(observations) >= END_CONFIRMATION_ATTEMPTS &&
    (onLastNumberedPage || observations.length >= maxAttempts)

  if (confirmedAbsent) {
    return { type: 'stop', complete: true, reason: 'end-of-book' }
  }

  if (observations.length < maxAttempts) {
    return { type: 'retry-navigation' }
  }

  // A reader that went away says nothing about where the book ends, even on
  // its last numbered page, so it is an ordinary stall there too — which also
  // allows it the ordinary number of reloads.
  return onLastNumberedPage && latest !== 'reader-lost'
    ? { type: 'stop', complete: false, reason: 'end-unconfirmed' }
    : { type: 'stop', complete: false, reason: 'navigation-failed' }
}

/*
 * Recovering from a reader that stopped responding.
 *
 * The Kindle web reader occasionally stops turning pages on an ordinary screen
 * — the same book captures straight past that screen on another run — and
 * stopping there costs the person a full re-capture from page 1. A fresh load
 * of the reader almost always gets it moving again, so a stall is answered by
 * reloading, going back to the page the capture had reached and carrying on.
 *
 * Two things must never happen along the way: a genuine ending mistaken for a
 * stall (the capture would reload and walk forward into back matter, or loop
 * at the last page forever), and a recovery that quietly drops screens. The
 * functions below decide both, and are kept apart from the browser driving so
 * they can be tested.
 */

/** Recoveries allowed in one capture, wherever they happen. */
export const MAX_CAPTURE_RECOVERIES = 3

/**
 * Recoveries allowed at one page before accepting that the reader will not get
 * past it.
 *
 * Two, because the first retry can land on a reader that is itself still
 * warming up; a second failure at the same spot after a fresh load is no
 * longer bad luck, and further reloads would only spend the recovery budget
 * the rest of the book might need.
 */
export const MAX_RECOVERIES_AT_ONE_PAGE = 2

/**
 * The same, for a stall on the last numbered page.
 *
 * One, because an `end-unconfirmed` stop is ambiguous in a way a mid-book
 * stall is not: some books end with the next-page control still enabled, and
 * no amount of reloading changes that. One fresh load is enough to tell a
 * stuck reader (it turns, or it drops the chevron and confirms the end) from a
 * book that simply ends like that; a second would cost every such book another
 * reload for nothing.
 */
export const MAX_RECOVERIES_AT_UNCONFIRMED_END = 1

/**
 * Stop reasons that mean "the reader stopped cooperating", as opposed to "the
 * book ended". Only these are worth a reload.
 *
 * - `navigation-failed`: a usable next-page control that won't turn, mid-book;
 *   or the reader gone from the page (signed out, unloaded) anywhere — a
 *   reload brings it back, through sign-in if need be.
 * - `end-unconfirmed`: the same on the last numbered page (see above).
 * - `no-page-nav`: the footer became unreadable, which is a rendering fault,
 *   not a position — a reload redraws it.
 *
 * `end-of-book` and `past-last-content-page` are the book telling us it has
 * finished, and `interrupted` is not a decision the capture loop ever makes.
 */
const STALL_REASONS: ReadonlySet<CaptureStopReason> =
  new Set<CaptureStopReason>([
    'navigation-failed',
    'end-unconfirmed',
    'no-page-nav'
  ])

/** Whether a stop reason is a stall that a recovery might get past. */
export function isStall(reason: CaptureStopReason): boolean {
  return STALL_REASONS.has(reason)
}

export interface RecoveryInput {
  /** Why the capture would stop now. */
  reason: CaptureStopReason
  /** The last page captured, which is where a recovery would resume. */
  page: number
  /** Recoveries already made in this capture, oldest first. */
  recoveries: readonly { page: number }[]
}

export type RecoveryDecision =
  | { type: 'recover' }
  | {
      type: 'give-up'
      /**
       * `not-a-stall`: the book ended, nothing to recover from.
       * `recovery-limit`: the capture has used all its recoveries.
       * `stuck-here`: recoveries at this page have already failed.
       */
      why: 'not-a-stall' | 'recovery-limit' | 'stuck-here'
    }

/**
 * Whether to reload the reader and carry on instead of stopping.
 *
 * "At this page" is judged by the last *captured* page, which is exactly where
 * a recovery resumes: if the capture stalls again without having captured
 * anything on a later page, the previous recovery didn't get it past the
 * problem. A recovery that fails outright (the reload itself errors) is
 * recorded all the same, so it counts here too and a reader that can't be
 * reloaded at all runs out of attempts rather than looping.
 */
export function shouldRecover({
  reason,
  page,
  recoveries
}: RecoveryInput): RecoveryDecision {
  if (!isStall(reason)) return { type: 'give-up', why: 'not-a-stall' }

  if (recoveries.length >= MAX_CAPTURE_RECOVERIES) {
    return { type: 'give-up', why: 'recovery-limit' }
  }

  const atThisPage = recoveries.filter((r) => r.page === page).length
  const allowedHere =
    reason === 'end-unconfirmed'
      ? MAX_RECOVERIES_AT_UNCONFIRMED_END
      : MAX_RECOVERIES_AT_ONE_PAGE
  if (atThisPage >= allowedHere) {
    return { type: 'give-up', why: 'stuck-here' }
  }

  return { type: 'recover' }
}

/** Where a capture is resuming after a recovery. */
export interface ResumeState {
  /** The page the reader was sent back to: the last page captured. */
  page: number
  /** Screens passed over so far because they had already been captured. */
  skipped: number
}

export interface ResumeScreenInput {
  resume: ResumeState
  /** Whether this screen's image is identical to one already captured. */
  alreadyCaptured: boolean
  /** The page the footer reports for this screen. */
  currentPage: number
  /** Whether the capture had captured anything before it stalled. */
  capturedAny: boolean
}

export type ResumeScreenDecision =
  /** Already captured: turn past it without saving it again. */
  | { type: 'skip' }
  /**
   * The first screen not captured before: capture it and every one after it
   * as normal. `possibleDuplicates` means the screens already captured for
   * this page were never recognised, so some of them may be captured twice.
   */
  | { type: 'capture'; possibleDuplicates: boolean }
  /**
   * The reader came back somewhere past the page it was sent to, without
   * showing a single screen we recognise. Screens between the two may be
   * missing, so this is treated as a failed recovery rather than carried on.
   */
  | { type: 'lost-place' }

/**
 * What to do with a screen seen while resuming after a recovery.
 *
 * A Kindle page number spans several screens, and going back to the last page
 * captured lands on its *first* screen, so the screens up to the one that
 * stalled come round again. They're recognised by their image: the same
 * content in the same reader settings renders to the same pixels, and a
 * screen identical to one already saved carries nothing new.
 *
 * When nothing matches — the reload rendered the page differently — the only
 * choices are to skip screens we can't recognise or to capture them again.
 * Capturing wins: a repeated screen shows up as repeated text that a reader
 * can see and skip, while a skipped one is a silent hole in the book that
 * nothing downstream can detect. The one case that can't be resolved by
 * capturing more is landing *past* where we were; that gives up rather than
 * guessing.
 */
export function resumeScreenDecision({
  resume,
  alreadyCaptured,
  currentPage,
  capturedAny
}: ResumeScreenInput): ResumeScreenDecision {
  if (alreadyCaptured) return { type: 'skip' }

  // Nothing had been captured, so there is nothing to duplicate or miss:
  // whatever the reader shows is where the capture starts.
  if (!capturedAny) return { type: 'capture', possibleDuplicates: false }

  // Having recognised at least one screen, we know the reader is rendering as
  // it did before and this is simply the next screen along.
  if (resume.skipped > 0) return { type: 'capture', possibleDuplicates: false }

  if (currentPage > resume.page) return { type: 'lost-place' }

  return { type: 'capture', possibleDuplicates: true }
}
