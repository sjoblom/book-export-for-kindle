import AppKit
import Foundation
import WebKit

/// The real `AppBackend`: one `ReaderSession` (the "Amazon" window) shared by
/// the library refresh, sign-in and capture — `AppModel` makes them take turns
/// — plus `BookPipeline` for the rest of a book.
///
/// The window stays minimized in the Dock while the library is read or a book
/// is captured (synthesized input reaches a minimized window; a closed one is
/// not guaranteed to render), and comes forward only for sign-in. Closing it
/// minimizes it instead; during sign-in, closing it means "not now".
@MainActor
public final class NativeBackend: NSObject, AppBackend, NSWindowDelegate {
  public static let libraryURL = URL(string: "https://read.amazon.com/kindle-library")!
  /// session.ts SIGN_IN_TIMEOUT_MS.
  public static let signInTimeout: TimeInterval = 10 * 60
  static let signInPoll: TimeInterval = 1
  static let libraryScriptTimeout: TimeInterval = 60

  public let session: ReaderSession
  public let outDir: URL
  /// Diagnostics (stderr by default).
  public var log: (String) -> Void = { line in
    FileHandle.standardError.write(Data("[kindle-export] \(line)\n".utf8))
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
  private var signingIn = false
  private var signInCancelled = false

  public init(outDir: URL) {
    self.outDir = outDir
    session = ReaderSession()
    super.init()
    session.window.title = "Amazon"
    session.window.delegate = self
    session.log = { [weak self] line in self?.log("reader: \(line)") }
  }

  // MARK: - window

  /// Keep the reader in the Dock, out of the way but alive.
  func park() {
    if !session.window.isMiniaturized { session.minimize() }
  }

  public func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === session.window else { return true }
    // The web view must survive: it holds the session and may be mid-capture.
    if signingIn { signInCancelled = true }
    park()
    return false
  }

  // MARK: - sign-in

  /// session.ts `isSignedInUrl`: on the reader's domain and not on a sign-in
  /// path.
  public nonisolated static func isSignedInUrl(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.host == "read.amazon.com" else { return false }
    return url.path.range(of: #"/ap/signin|/gp/signin"#, options: .regularExpression) == nil
  }

  /// session.ts `interactiveLogin`: open the library; if Amazon wants a
  /// sign-in, show the window and watch the URL until it lands back on the
  /// reader, then put the window away again.
  public func signIn() async -> Bool {
    do {
      try await session.load(Self.libraryURL)
    } catch {
      return false
    }
    if Self.isSignedInUrl(session.currentURL) {
      park()
      return true
    }
    return await waitForSignIn()
  }

  /// Show the window and wait for a signed-in URL, the person closing the
  /// window, or the timeout.
  func waitForSignIn() async -> Bool {
    signingIn = true
    signInCancelled = false
    session.show()
    defer {
      signingIn = false
      park()
    }

    let deadline = Date().addingTimeInterval(Self.signInTimeout)
    while !signInCancelled, Date() < deadline {
      if Self.isSignedInUrl(session.currentURL), !session.webView.isLoading { return true }
      do {
        try await Task.sleep(nanoseconds: UInt64(Self.signInPoll * 1e9))
      } catch {
        return false
      }
    }
    return false
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

  /// BookPipeline's capture step: CaptureEngine on the shared reader, parked
  /// in the Dock.
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
          .info("Amazon needs you to sign in — finish signing in in the Amazon window"))
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
