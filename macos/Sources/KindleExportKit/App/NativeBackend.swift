import AppKit
import Foundation
import WebKit

/// The real `AppBackend`: one `ReaderSession` shared by the library refresh,
/// sign-in and capture — `AppModel` makes them take turns — plus
/// `BookPipeline` for the rest of a book.
///
/// The reader's web view lives in an invisible, off-screen host window while
/// the library is read or a book is captured (it has to be in *a* window to
/// render and to take synthesized input). When Amazon wants the person to
/// sign in, the backend asks for it to be shown (`placement` becomes
/// `.signIn`): the app then moves the same web view into its main window,
/// and back into the host once a signed-in page is reached or the person
/// cancels.
@MainActor
public final class NativeBackend: NSObject, AppBackend {
  public static let libraryURL = URL(string: "https://read.amazon.com/kindle-library")!
  /// session.ts SIGN_IN_TIMEOUT_MS.
  public static let signInTimeout: TimeInterval = 10 * 60
  static let signInPoll: TimeInterval = 0.5
  /// A signed-in address must hold this many polls in a row: a page that is
  /// about to be sent on to sign-in again sits on the reader's domain for a
  /// moment first.
  static let signedInPollsNeeded = 2
  static let libraryScriptTimeout: TimeInterval = 60

  /// Where the reader's web view should be: out of sight, or in front of the
  /// person for Amazon's sign-in.
  public enum ReaderPlacement: Equatable, Sendable {
    case background
    case signIn
  }

  public let session: ReaderSession
  public let outDir: URL
  /// Diagnostics (stderr by default).
  public var log: (String) -> Void = { line in
    FileHandle.standardError.write(Data("[kindle-export] \(line)\n".utf8))
  }

  /// Where the web view should be now. The app moves it (`ReaderSession
  /// .present(in:)` for `.signIn`, `hostInBackground()` for `.background`)
  /// in `onPlacementChange`.
  public private(set) var placement: ReaderPlacement = .background
  public var onPlacementChange: ((ReaderPlacement) -> Void)?

  /// Whether a signed-in page has been reached (tests replace this).
  var isSignedIn: @MainActor (ReaderSession) -> Bool = { session in
    NativeBackend.isSignedInUrl(session.currentURL) && !session.webView.isLoading
  }

  private var captureCore: JSCore?
  private var libraryService: LibraryService?
  private lazy var pipeline = BookPipeline(
    outDir: outDir,
    capture: { [weak self] asin, store in
      guard let self else { throw CancellationError() }
      try await self.capture(asin: asin, outDir: store.outDir)
    })

  /// Where a running book's events go, for what the capture itself has to say.
  private var currentEmit: (@MainActor @Sendable (PipelineEvent) -> Void)?
  public private(set) var signingIn = false
  private var signInCancelled = false

  public init(outDir: URL, session: ReaderSession? = nil) {
    self.outDir = outDir
    self.session = session ?? ReaderSession()
    super.init()
    self.session.log = { [weak self] line in self?.log("reader: \(line)") }
    self.session.hostInBackground()
  }

  // MARK: - placement

  private func setPlacement(_ next: ReaderPlacement) {
    guard placement != next else { return }
    placement = next
    if let onPlacementChange {
      onPlacementChange(next)
    } else if next == .background {
      session.hostInBackground()
    }
  }

  /// Make sure the reader is back out of sight before background work.
  func park() {
    setPlacement(.background)
    session.hostInBackground()
  }

  /// The person pressed Cancel above Amazon's sign-in page: not now.
  public func cancelSignIn() {
    if signingIn { signInCancelled = true }
  }

  // MARK: - sign-in

  /// session.ts `isSignedInUrl`: on the reader's domain and not on a sign-in
  /// path.
  public nonisolated static func isSignedInUrl(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.host == "read.amazon.com" else { return false }
    return url.path.range(of: #"/ap/signin|/gp/signin"#, options: .regularExpression) == nil
  }

  /// session.ts `interactiveLogin`: open the library; if Amazon wants a
  /// sign-in, show its page and watch the address until it lands back on
  /// the reader, then put the reader away again.
  public func signIn() async -> Bool {
    park()
    do {
      try await session.load(Self.libraryURL)
      // As in fetchLibrary: a signed-out session reaches sign-in only after a
      // scripted redirect, and checking before it has happened reads as
      // "already signed in".
      try await Task.sleep(nanoseconds: Self.redirectSettleNanoseconds)
    } catch {
      return false
    }
    if Self.isSignedInUrl(session.currentURL) {
      return true
    }
    return await waitForSignIn()
  }

  /// Show Amazon's page and wait for a signed-in page, Cancel, or the
  /// timeout. The reader goes back out of sight either way.
  func waitForSignIn() async -> Bool {
    signingIn = true
    signInCancelled = false
    setPlacement(.signIn)
    defer {
      signingIn = false
      park()
    }

    let deadline = Date().addingTimeInterval(Self.signInTimeout)
    var signedInPolls = 0
    while !signInCancelled, Date() < deadline {
      signedInPolls = isSignedIn(session) ? signedInPolls + 1 : 0
      if signedInPolls >= Self.signedInPollsNeeded { return true }
      do {
        try await Task.sleep(nanoseconds: UInt64(Self.signInPoll * 1e9))
      } catch {
        return false
      }
    }
    return false
  }

  /// Remove everything WebKit keeps for Amazon's sites — the session
  /// cookies above all — and leave the reader on a blank page. Only Amazon's
  /// records go: the app has no others, but a blanket wipe would also drop
  /// anything WebKit keeps for itself.
  public func signOut() async {
    let store = session.webView.configuration.websiteDataStore
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    let records = await store.dataRecords(ofTypes: types)
    let amazon = records.filter { $0.displayName.localizedCaseInsensitiveContains("amazon") }
    await store.removeData(ofTypes: types, for: amazon)
    session.webView.load(URLRequest(url: URL(string: "about:blank")!))
  }

  // MARK: - library

  /// How long a freshly loaded page gets to redirect a signed-out session.
  static let redirectSettleNanoseconds: UInt64 = 1_500_000_000

  public func fetchLibrary() async throws -> [LibraryBook] {
    park()
    try await session.load(Self.libraryURL)
    // A signed-out session lands on the library page first and is sent on to
    // sign-in by a script a moment later, so the address right after loading
    // proves nothing. Give the redirect time to happen before trusting it.
    try await Task.sleep(nanoseconds: Self.redirectSettleNanoseconds)
    guard Self.isSignedInUrl(session.currentURL) else {
      throw LibraryService.LibraryError.notSignedIn
    }

    if libraryService == nil { libraryService = try LibraryService() }
    let service = libraryService!
    let webView = session.webView
    do {
      return try await service.fetchLibrary(evaluate: { script in
        try await Self.callAsync(script, in: webView, timeout: Self.libraryScriptTimeout)
      })
    } catch let error as LibraryService.LibraryError {
      throw error
    } catch {
      // The request died mid-flight — typically because the page navigated
      // away under it, which a signed-out session does on its way to sign-in.
      // Where the page went decides what this was.
      try await Task.sleep(nanoseconds: Self.redirectSettleNanoseconds)
      if !Self.isSignedInUrl(session.currentURL) {
        throw LibraryService.LibraryError.notSignedIn
      }
      throw error
    }
  }

  /// Run the body of an async function in the page (LibraryService's
  /// contract: `callAsyncJavaScript`, not `evaluateJavaScript`, because the
  /// script awaits `fetch`). In WebKit's default client world, so the
  /// reader's own hooks and globals are neither seen nor disturbed; `fetch`
  /// there still carries the page's cookies.
  @MainActor
  static func callAsync(_ script: String, in webView: WKWebView, timeout: TimeInterval)
    async throws -> Any?
  {
    try await withCheckedThrowingContinuation { continuation in
      var finished = false
      let finish: (Result<Any?, Error>) -> Void = { result in
        if finished { return }
        finished = true
        continuation.resume(with: result)
      }
      webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
        MainActor.assumeIsolated {
          switch result {
          case .success(let value): finish(.success(value))
          case .failure(let error): finish(.failure(error))
          }
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        MainActor.assumeIsolated {
          finish(.failure(LibraryService.LibraryError.requestFailed("timed out")))
        }
      }
    }
  }

  // MARK: - books

  public func processBook(
    asin: String, options: BookPipeline.Options,
    emit: @escaping @MainActor @Sendable (PipelineEvent) -> Void
  ) async throws -> BookResult {
    currentEmit = emit
    defer { currentEmit = nil }
    return try await pipeline.process(asin: asin, options: options) { event in
      // Main-queue FIFO keeps events in order, and ahead of the result.
      DispatchQueue.main.async { MainActor.assumeIsolated { emit(event) } }
    }
  }

  /// BookPipeline's capture step: CaptureEngine on the shared reader, out of
  /// sight in its host window.
  func capture(asin: String, outDir: URL) async throws {
    if captureCore == nil { captureCore = try JSCore() }
    park()

    let engine = CaptureEngine(
      session: session, options: CaptureEngine.Options(asin: asin, outDir: outDir),
      core: captureCore!)
    engine.onEvent = { [weak self] event in
      guard let self else { return }
      switch event {
      case .message(let message):
        self.log("[\(asin)] \(message)")
      case .progress:
        break  // BookPipeline reads progress back from metadata.json.
      case .needsSignIn:
        self.currentEmit?(
          .info("Amazon needs you to sign in — its sign-in page is shown in the app window"))
      }
    }
    engine.signInHandler = { [weak self] _ in
      guard let self, await self.waitForSignIn() else {
        throw CaptureEngine.CaptureError.needsSignIn
      }
    }

    let result = try await engine.run()
    log(
      "[\(asin)] capture \(result.complete ? "complete" : "incomplete"): \(result.reason), "
        + "page \(result.lastPage) of \(result.totalContentPages)")
  }
}
