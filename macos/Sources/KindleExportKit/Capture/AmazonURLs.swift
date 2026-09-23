import Foundation

/// Which Amazon pages mean "signed in" and which mean "signed out" — one
/// definition for the capture (`ReaderSession.isOnSignIn`) and the app's
/// sign-in window (`NativeBackend.isSignedInUrl`), so a page one of them
/// treats as the reader the other can't treat as sign-in.
///
/// Mirrors session.ts `SIGNED_OUT_PATH_REGEX` / `isSignedInUrl` and
/// extract-kindle-book.ts `isSignedOutUrl`.
public enum AmazonURLs {
  /// The reader's host; the only place a signed-in Kindle session lives.
  static let readerHost = "read.amazon.com"

  /// Sign-in paths shared with session.ts. `/landing` is where a session with
  /// no Amazon cookies at all is sent — on the reader's own domain, so the
  /// domain alone never proves a sign-in.
  static let signedOutPathPattern = #"/ap/signin|/gp/signin|^/landing"#

  /// On the reader's domain and not on a signed-out page.
  public static func isSignedIn(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.host == readerHost else { return false }
    return !isSignedOutPath(url.path)
  }

  /// On one of Amazon's signed-out pages: the sign-in form, the challenges
  /// after it (`/ap/cvf`, `/ap/mfa` — everything under `/ap/` is Amazon's
  /// sign-in portal, and landing on one mid-flow still means "not signed in
  /// yet"), or the reader's signed-out landing page.
  public static func isSignedOut(_ url: URL?) -> Bool {
    guard let url, let host = url.host, isAmazonHost(host) else { return false }
    return isSignedOutPath(url.path)
  }

  /// The reader's signed-out landing page, whose "Sign in with your account"
  /// button leads to the sign-in form.
  public static func isLanding(_ url: URL?) -> Bool {
    guard let url, url.host == readerHost else { return false }
    return url.path.hasPrefix("/landing")
  }

  static func isSignedOutPath(_ path: String) -> Bool {
    path.hasPrefix("/ap/")
      || path.range(of: signedOutPathPattern, options: .regularExpression) != nil
  }

  static func isAmazonHost(_ host: String) -> Bool {
    host == "amazon.com" || host.hasSuffix(".amazon.com")
  }
}
