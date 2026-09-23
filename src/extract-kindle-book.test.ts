import { describe, expect, it } from 'vitest'

import { isSignedOutUrl } from './extract-kindle-book'
import { isSignedInUrl } from './session'

describe('isSignedOutUrl', () => {
  it('recognises every page Amazon sends a signed-out session to', () => {
    for (const url of [
      'https://www.amazon.com/ap/signin?openid.return_to=https://read.amazon.com',
      'https://read.amazon.com/ap/signin',
      'https://www.amazon.com/gp/signin/x',
      // A session with no Amazon cookies at all: the reader's own domain.
      'https://read.amazon.com/landing',
      'https://read.amazon.com/landing?ref=x',
      // The challenges that follow the sign-in form are part of signing in.
      'https://www.amazon.com/ap/cvf/request?arb=1',
      'https://www.amazon.com/ap/mfa?arb=1'
    ]) {
      expect(isSignedOutUrl(url), url).toBe(true)
      // The two definitions must never both claim a URL.
      expect(isSignedInUrl(url), url).toBe(false)
    }
  })

  it('does not mistake the reader, or other sites, for a sign-in page', () => {
    for (const url of [
      'https://read.amazon.com/?asin=B00TEST',
      'https://read.amazon.com/kindle-library',
      'https://example.com/ap/signin',
      'https://read.amazon.com.evil.example/landing',
      'about:blank',
      'not a url'
    ]) {
      expect(isSignedOutUrl(url), url).toBe(false)
    }
  })
})
