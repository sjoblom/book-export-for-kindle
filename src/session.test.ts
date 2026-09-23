import { describe, expect, it } from 'vitest'

import {
  isSignedInUrl,
  type SignInContext,
  type SignInPage,
  signInWithContext,
  waitForSignIn
} from './session'

describe('isSignedInUrl', () => {
  it('accepts the signed-in library and reader', () => {
    expect(isSignedInUrl('https://read.amazon.com/kindle-library')).toBe(true)
    expect(isSignedInUrl('https://read.amazon.com/?asin=B01H4G2J1U')).toBe(true)
    expect(isSignedInUrl('https://read.amazon.com/')).toBe(true)
  })

  it('rejects Amazon sign-in pages, wherever they live', () => {
    expect(
      isSignedInUrl('https://www.amazon.com/ap/signin?openid.pape=x')
    ).toBe(false)
    // An expired session can bounce to a signin path on the reader host too.
    expect(isSignedInUrl('https://read.amazon.com/ap/signin')).toBe(false)
    expect(isSignedInUrl('https://read.amazon.com/gp/signin')).toBe(false)
    // A session with no Amazon cookies lands on the reader's own domain.
    expect(isSignedInUrl('https://read.amazon.com/landing')).toBe(false)
  })

  it('rejects everything that is not the reader host over https', () => {
    // A hostname that merely starts with the reader's must not pass — this is
    // what a substring check would get wrong.
    expect(isSignedInUrl('https://read.amazon.com.evil.example/')).toBe(false)
    expect(isSignedInUrl('http://read.amazon.com/kindle-library')).toBe(false)
    expect(isSignedInUrl('https://www.amazon.com/')).toBe(false)
    expect(isSignedInUrl('about:blank')).toBe(false)
    expect(isSignedInUrl('')).toBe(false)
    expect(isSignedInUrl('not a url')).toBe(false)
  })

  it('ignores signin-looking strings in the query, not the path', () => {
    expect(
      isSignedInUrl('https://read.amazon.com/kindle-library?from=/ap/signin')
    ).toBe(true)
  })
})

const LIBRARY = 'https://read.amazon.com/kindle-library'
const LANDING = 'https://read.amazon.com/landing'
const AMAZON_SIGN_IN = 'https://www.amazon.com/ap/signin?openid.return_to=x'

/** Fast timings, so the tests don't sit through the real 1.5 s settle. */
const FAST = { pollMs: 10, settleMs: 60, timeoutMs: 400 }

/** A page whose address is whatever the test says it is right now. */
class FakePage implements SignInPage {
  current = 'about:blank'
  scripts: string[] = []
  onGoto: (url: string) => void = (url) => {
    this.current = url
  }
  onEvaluate: () => void = () => {}

  url() {
    return this.current
  }

  async goto(url: string) {
    this.onGoto(url)
  }

  async evaluate(script: string) {
    this.scripts.push(script)
    this.onEvaluate()
    return true
  }
}

/** A page that reports the given addresses in turn, then keeps the last. */
class ScriptedPage extends FakePage {
  constructor(private readonly urls: string[]) {
    super()
  }

  override url() {
    return this.urls.length > 1 ? this.urls.shift()! : this.urls[0]!
  }
}

function fakeContext(page: SignInPage): SignInContext {
  return {
    pages: () => [page],
    newPage: async () => page,
    on: () => {}
  }
}

describe('waitForSignIn', () => {
  it('does not trust one signed-in reading on its way somewhere else', async () => {
    // Mid-flow, the reader's domain can show for a moment before Amazon moves
    // on to its sign-in form.
    const page = new ScriptedPage([AMAZON_SIGN_IN, LIBRARY, AMAZON_SIGN_IN])

    expect(await waitForSignIn(fakeContext(page), FAST)).toBe(false)
  })

  it('confirms a signed-in page that holds across polls', async () => {
    const page = new ScriptedPage([AMAZON_SIGN_IN, LIBRARY, LIBRARY])

    expect(await waitForSignIn(fakeContext(page), FAST)).toBe(true)
  })

  it('gives up when the window is closed', async () => {
    const page = new FakePage()
    page.current = AMAZON_SIGN_IN
    const context: SignInContext = {
      ...fakeContext(page),
      on: (_event, listener) => setTimeout(listener, 30)
    }

    expect(await waitForSignIn(context, { ...FAST, timeoutMs: 5000 })).toBe(
      false
    )
  })
})

/**
 * A signed-out session as Amazon serves it: the library reaches
 * DOMContentLoaded, and its script then redirects to /landing.
 */
function signedOutPage(redirectAfterMs = 20) {
  const page = new FakePage()
  page.onGoto = (url) => {
    page.current = url
    setTimeout(() => {
      page.current = LANDING
    }, redirectAfterMs)
  }
  // The landing page's sign-in button goes to Amazon's form.
  page.onEvaluate = () => {
    page.current = AMAZON_SIGN_IN
  }
  return page
}

describe('signInWithContext', () => {
  it('does not report success when the library redirects to /landing', async () => {
    const page = signedOutPage()

    expect(await signInWithContext(fakeContext(page), FAST)).toBe(false)
    // The person was taken to Amazon's form, not left on the landing page.
    expect(page.scripts).toHaveLength(1)
    expect(page.scripts[0]).toContain('#top-sign-in-btn')
    // The text fallback's regex survives being written in a template literal.
    expect(page.scripts[0]).toContain(String.raw`^\s*sign in\s*$`)
    expect(page.current).toBe(AMAZON_SIGN_IN)
  })

  it("confirms once the person has signed in on Amazon's form", async () => {
    const page = signedOutPage()
    const onEvaluate = page.onEvaluate
    page.onEvaluate = () => {
      onEvaluate()
      setTimeout(() => {
        page.current = LIBRARY
      }, 50)
    }

    expect(await signInWithContext(fakeContext(page), FAST)).toBe(true)
    expect(page.current).toBe(LIBRARY)
  })

  it('confirms an existing session without pressing anything', async () => {
    const page = new FakePage()

    expect(await signInWithContext(fakeContext(page), FAST)).toBe(true)
    expect(page.scripts).toEqual([])
  })

  it('treats a navigation that throws as not confirmed', async () => {
    const page = new FakePage()
    page.onGoto = () => {
      throw new Error('Target page, context or browser has been closed')
    }

    expect(await signInWithContext(fakeContext(page), FAST)).toBe(false)
  })
})
