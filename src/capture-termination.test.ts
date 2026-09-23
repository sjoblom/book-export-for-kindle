import { describe, expect, it } from 'vitest'

import {
  chevronClickTimeoutMs,
  CLICK_FAILED_TIMEOUT_MS,
  END_CONFIRMATION_ATTEMPTS,
  END_CONFIRMATION_CLICK_TIMEOUT_MS,
  END_CONFIRMATION_MAX_ATTEMPTS,
  END_CONFIRMATION_TIMEOUT_MS,
  isOnLastNumberedPage,
  isStall,
  MAX_CAPTURE_RECOVERIES,
  MAX_RECOVERIES_AT_ONE_PAGE,
  MAX_RECOVERIES_AT_UNCONFIRMED_END,
  maxNavigationAttempts,
  NAVIGATION_ATTEMPTS,
  NAVIGATION_CLICK_TIMEOUT_MS,
  NAVIGATION_TIMEOUT_MS,
  type NavigationResult,
  navigationTimeoutMs,
  resumeScreenDecision,
  shouldRecover,
  shouldStopBeforeCapture,
  shouldStopCapture
} from './capture-termination'

describe('isOnLastNumberedPage', () => {
  it('recognises the footer reporting the final page', () => {
    expect(isOnLastNumberedPage({ value: 145, total: 145 })).toBe(true)
    // Footers occasionally overshoot their own total in back matter.
    expect(isOnLastNumberedPage({ value: 146, total: 145 })).toBe(true)
  })

  it('is false mid-book, and whenever the footer is unusable', () => {
    expect(isOnLastNumberedPage({ value: 144, total: 145 })).toBe(false)
    expect(isOnLastNumberedPage({ value: undefined, total: 145 })).toBe(false)
    // A book whose footer reports locations can have no total at all; that is
    // not a reason to believe we're at the end.
    expect(isOnLastNumberedPage({ value: 8000, total: 0 })).toBe(false)
  })
})

describe('shouldStopCapture: a last numbered page spanning several screens', () => {
  const onLastNumberedPage = true
  const maxAttempts = maxNavigationAttempts(onLastNumberedPage)
  const decide = (observations: NavigationResult[]) =>
    shouldStopCapture({ observations, onLastNumberedPage, maxAttempts })

  it('keeps capturing while the reader still turns the page', () => {
    // The regression this exists for: page 145 of 145 covers three screens.
    // The footer reads "145 of 145" on all three, and stopping on the first
    // one silently dropped two screens while claiming the book was complete.
    expect(decide(['navigated'])).toEqual({ type: 'capture-next-screen' })
    expect(decide(['stalled', 'navigated'])).toEqual({
      type: 'capture-next-screen'
    })
  })

  it('declares the end only once the chevron has stayed gone', () => {
    // The chevron vanishes briefly mid-render too, so one sighting is a hint
    // and the second, a few seconds later, is the confirmation.
    expect(decide(['no-next-page'])).toEqual({ type: 'retry-navigation' })
    expect(decide(['no-next-page', 'no-next-page'])).toEqual({
      type: 'stop',
      complete: true,
      reason: 'end-of-book'
    })
  })

  it('still confirms an end that a single stalled render preceded', () => {
    expect(decide(['stalled', 'no-next-page'])).toEqual({
      type: 'retry-navigation'
    })
    expect(decide(['stalled', 'no-next-page', 'no-next-page'])).toEqual({
      type: 'stop',
      complete: true,
      reason: 'end-of-book'
    })
  })

  it('does not count an absence that a usable chevron interrupted', () => {
    // Gone, back, gone: the first absence was the render, so the last one is
    // a single sighting again — and the budget is spent.
    expect(decide(['no-next-page', 'stalled', 'no-next-page'])).toEqual({
      type: 'stop',
      complete: false,
      reason: 'end-unconfirmed'
    })
  })

  it('never calls a stalled reader on the final page a finished book', () => {
    expect(decide(['stalled'])).toEqual({ type: 'retry-navigation' })
    expect(decide(['stalled', 'stalled'])).toEqual({
      type: 'retry-navigation'
    })

    // A usable next-page control is still on screen and the reader would not
    // turn to it. The footer counts pages, not screens, so it cannot say the
    // screens after this one don't exist; the honest record is "unconfirmed",
    // which the person can resolve by capturing again.
    expect(decide(['stalled', 'stalled', 'stalled'])).toEqual({
      type: 'stop',
      complete: false,
      reason: 'end-unconfirmed'
    })
    // The single absence at the very end is one sighting, not a confirmation.
    expect(decide(['stalled', 'stalled', 'no-next-page'])).toEqual({
      type: 'stop',
      complete: false,
      reason: 'end-unconfirmed'
    })
    expect(decide(['stalled', 'no-next-page', 'stalled'])).toEqual({
      type: 'stop',
      complete: false,
      reason: 'end-unconfirmed'
    })
  })
})

const stalls = (n: number): NavigationResult[] =>
  Array.from({ length: n }, () => 'stalled')

describe('shouldStopCapture: mid-book', () => {
  const onLastNumberedPage = false
  const maxAttempts = maxNavigationAttempts(onLastNumberedPage)
  const decide = (observations: NavigationResult[]) =>
    shouldStopCapture({ observations, onLastNumberedPage, maxAttempts })

  it('retries a stalled turn until the attempts run out', () => {
    for (let attempt = 1; attempt < maxAttempts; attempt++) {
      expect(decide(stalls(attempt))).toEqual({ type: 'retry-navigation' })
    }

    expect(decide(stalls(maxAttempts))).toEqual({
      type: 'stop',
      complete: false,
      reason: 'navigation-failed'
    })
  })

  it('retries a briefly missing chevron rather than calling it the end', () => {
    // Kindle drops the chevron mid-render. Believing it the first time would
    // mark a book complete in the middle of a chapter.
    expect(decide(['no-next-page'])).toEqual({ type: 'retry-navigation' })
    expect(decide(['no-next-page', 'no-next-page'])).toEqual({
      type: 'retry-navigation'
    })
  })

  it('accepts a chevron that has stayed missing through the last attempts', () => {
    // Books whose footer never reports the final page end here instead.
    expect(
      decide([...stalls(maxAttempts - 2), 'no-next-page', 'no-next-page'])
    ).toEqual({ type: 'stop', complete: true, reason: 'end-of-book' })
  })

  it('does not accept a chevron missing only on the final attempt', () => {
    expect(decide([...stalls(maxAttempts - 1), 'no-next-page'])).toEqual({
      type: 'stop',
      complete: false,
      reason: 'navigation-failed'
    })
    expect(
      decide([
        ...stalls(maxAttempts - 3),
        'no-next-page',
        'stalled',
        'no-next-page'
      ])
    ).toEqual({ type: 'stop', complete: false, reason: 'navigation-failed' })
  })

  it('carries on as soon as a turn lands', () => {
    expect(decide([...stalls(2), 'navigated'])).toEqual({
      type: 'capture-next-screen'
    })
  })
})

describe('shouldStopBeforeCapture', () => {
  it('captures an ordinary content page', () => {
    expect(
      shouldStopBeforeCapture({
        hasPageNav: true,
        currentPage: 12,
        totalContentPages: 480
      })
    ).toBeUndefined()
  })

  it('captures every screen of the last content page', () => {
    // The check is `>`, not `>=`: page 480 of 480 may span several screens and
    // all of them are content.
    expect(
      shouldStopBeforeCapture({
        hasPageNav: true,
        currentPage: 480,
        totalContentPages: 480
      })
    ).toBeUndefined()
  })

  it('stops, complete, once the page number is into the back matter', () => {
    expect(
      shouldStopBeforeCapture({
        hasPageNav: true,
        currentPage: 481,
        totalContentPages: 480
      })
    ).toEqual({
      type: 'stop',
      complete: true,
      reason: 'past-last-content-page'
    })
  })

  it('stops, incomplete, when the position becomes unreadable', () => {
    expect(
      shouldStopBeforeCapture({
        hasPageNav: false,
        currentPage: 3,
        totalContentPages: 480
      })
    ).toEqual({ type: 'stop', complete: false, reason: 'no-page-nav' })
  })
})

describe('navigation budgets', () => {
  it('spends a few short attempts confirming the end of the book', () => {
    // (b) of the fix: a finished book must not cost 5 × 10s to notice.
    expect(maxNavigationAttempts(true)).toBe(END_CONFIRMATION_MAX_ATTEMPTS)
    expect(END_CONFIRMATION_MAX_ATTEMPTS).toBeLessThan(NAVIGATION_ATTEMPTS)
    // ...but a confirmation needs more than one sighting, and the budget has
    // to leave room for it.
    expect(END_CONFIRMATION_ATTEMPTS).toBeGreaterThan(1)
    expect(END_CONFIRMATION_MAX_ATTEMPTS).toBeGreaterThan(
      END_CONFIRMATION_ATTEMPTS
    )
    expect(
      navigationTimeoutMs({ onLastNumberedPage: true, clickFailed: false })
    ).toBe(END_CONFIRMATION_TIMEOUT_MS)
    expect(END_CONFIRMATION_TIMEOUT_MS).toBeLessThan(NAVIGATION_TIMEOUT_MS)
    // The click itself is part of that cost: at the end there's usually no
    // chevron, so this timeout is always spent in full.
    expect(chevronClickTimeoutMs(true)).toBe(END_CONFIRMATION_CLICK_TIMEOUT_MS)
    expect(END_CONFIRMATION_CLICK_TIMEOUT_MS).toBeLessThan(
      NAVIGATION_CLICK_TIMEOUT_MS
    )
  })

  it('gives an ordinary page turn the full budget', () => {
    expect(maxNavigationAttempts(false)).toBe(NAVIGATION_ATTEMPTS)
    expect(
      navigationTimeoutMs({ onLastNumberedPage: false, clickFailed: false })
    ).toBe(NAVIGATION_TIMEOUT_MS)
    expect(chevronClickTimeoutMs(false)).toBe(NAVIGATION_CLICK_TIMEOUT_MS)
  })

  it('waits only briefly when the click itself never landed', () => {
    for (const onLastNumberedPage of [true, false]) {
      expect(
        navigationTimeoutMs({ onLastNumberedPage, clickFailed: true })
      ).toBe(CLICK_FAILED_TIMEOUT_MS)
    }
  })
})

describe('shouldRecover', () => {
  it('never reloads after a genuine ending', () => {
    // Reloading here would walk the capture on into back matter, or have it
    // circle the last page for ever.
    for (const reason of ['end-of-book', 'past-last-content-page'] as const) {
      expect(isStall(reason)).toBe(false)
      expect(shouldRecover({ reason, page: 300, recoveries: [] })).toEqual({
        type: 'give-up',
        why: 'not-a-stall'
      })
    }
  })

  it('does not treat an interrupted run as a stall', () => {
    expect(isStall('interrupted')).toBe(false)
  })

  it('recovers from a reader that stopped turning mid-book', () => {
    // The regression this exists for: a 371-page book stopped at page 150 on
    // an ordinary text page that another run turned straight past.
    expect(
      shouldRecover({ reason: 'navigation-failed', page: 150, recoveries: [] })
    ).toEqual({ type: 'recover' })
  })

  it('recovers from a lost footer and an unconfirmed end', () => {
    for (const reason of ['no-page-nav', 'end-unconfirmed'] as const) {
      expect(isStall(reason)).toBe(true)
      expect(shouldRecover({ reason, page: 371, recoveries: [] })).toEqual({
        type: 'recover'
      })
    }
  })

  it('gives up on a page that recovery has already failed to get past', () => {
    const at150 = { page: 150 }
    expect(MAX_RECOVERIES_AT_ONE_PAGE).toBe(2)
    expect(
      shouldRecover({
        reason: 'navigation-failed',
        page: 150,
        recoveries: [at150]
      })
    ).toEqual({ type: 'recover' })
    expect(
      shouldRecover({
        reason: 'navigation-failed',
        page: 150,
        recoveries: [at150, at150]
      })
    ).toEqual({ type: 'give-up', why: 'stuck-here' })
  })

  it('counts only recoveries at the same page against that page', () => {
    // Progress in between means the earlier recovery worked; a new stall
    // further on is a new problem.
    expect(
      shouldRecover({
        reason: 'navigation-failed',
        page: 200,
        recoveries: [{ page: 150 }, { page: 150 }]
      })
    ).toEqual({ type: 'recover' })
  })

  it('tries an unconfirmed end only once', () => {
    // Some books end with the chevron still enabled; after one fresh load
    // fails to turn, reloading again only costs time on every such book.
    expect(MAX_RECOVERIES_AT_UNCONFIRMED_END).toBe(1)
    expect(
      shouldRecover({
        reason: 'end-unconfirmed',
        page: 371,
        recoveries: [{ page: 371 }]
      })
    ).toEqual({ type: 'give-up', why: 'stuck-here' })
  })

  it('stops recovering once the capture has used its budget', () => {
    const recoveries = Array.from(
      { length: MAX_CAPTURE_RECOVERIES },
      (_, i) => ({ page: 10 * (i + 1) })
    )
    expect(
      shouldRecover({ reason: 'navigation-failed', page: 999, recoveries })
    ).toEqual({ type: 'give-up', why: 'recovery-limit' })
    expect(
      shouldRecover({
        reason: 'navigation-failed',
        page: 999,
        recoveries: recoveries.slice(1)
      })
    ).toEqual({ type: 'recover' })
  })

  it('still reports a genuine ending as one when the budget is spent', () => {
    // The reason given back is what the log says; an ending is never
    // described as a failed recovery.
    const recoveries = Array.from({ length: MAX_CAPTURE_RECOVERIES }, () => ({
      page: 5
    }))
    expect(
      shouldRecover({ reason: 'end-of-book', page: 5, recoveries })
    ).toEqual({ type: 'give-up', why: 'not-a-stall' })
  })
})

const resume = (skipped = 0) => ({ page: 150, skipped })

describe('resumeScreenDecision', () => {
  it('passes over screens already captured', () => {
    // Going back to page 150 lands on its first screen; the ones up to where
    // the reader stalled come round again and must not be saved twice.
    expect(
      resumeScreenDecision({
        resume: resume(),
        alreadyCaptured: true,
        currentPage: 150,
        capturedAny: true
      })
    ).toEqual({ type: 'skip' })
    expect(
      resumeScreenDecision({
        resume: resume(2),
        alreadyCaptured: true,
        currentPage: 150,
        capturedAny: true
      })
    ).toEqual({ type: 'skip' })
  })

  it('resumes at the first new screen, on the same page or the next', () => {
    // The stalled screen may have been the last one of its page, in which
    // case the first new screen belongs to the page after.
    for (const currentPage of [150, 151]) {
      expect(
        resumeScreenDecision({
          resume: resume(2),
          alreadyCaptured: false,
          currentPage,
          capturedAny: true
        })
      ).toEqual({ type: 'capture', possibleDuplicates: false })
    }
  })

  it('captures rather than skips when nothing is recognised', () => {
    // The reload rendered the page differently. Capturing again risks a
    // repeated screen; skipping would risk a silent hole in the book.
    expect(
      resumeScreenDecision({
        resume: resume(),
        alreadyCaptured: false,
        currentPage: 150,
        capturedAny: true
      })
    ).toEqual({ type: 'capture', possibleDuplicates: true })
    // Landing short of the page (a walk that stopped early) is the same.
    expect(
      resumeScreenDecision({
        resume: resume(),
        alreadyCaptured: false,
        currentPage: 149,
        capturedAny: true
      })
    ).toEqual({ type: 'capture', possibleDuplicates: true })
  })

  it('refuses to carry on from past where the capture was', () => {
    // Nothing recognised and already beyond the page it was sent to: the
    // screens in between may never be captured, so this is a failed recovery.
    expect(
      resumeScreenDecision({
        resume: resume(),
        alreadyCaptured: false,
        currentPage: 151,
        capturedAny: true
      })
    ).toEqual({ type: 'lost-place' })
  })

  it('simply starts when the stall came before anything was captured', () => {
    expect(
      resumeScreenDecision({
        resume: { page: 1, skipped: 0 },
        alreadyCaptured: false,
        currentPage: 3,
        capturedAny: false
      })
    ).toEqual({ type: 'capture', possibleDuplicates: false })
  })
})
