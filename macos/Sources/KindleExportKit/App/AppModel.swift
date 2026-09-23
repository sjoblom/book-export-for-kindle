import Foundation

/// The app: a port of src/serve.ts `App`, with the same state, the same
/// routes and the same queue — only the transport differs. The page talks to
/// it through `Bridge` (WKScriptMessageHandler) instead of HTTP + SSE, with
/// the method, path and JSON body the HTTP call would have used.
///
/// The app does as much as it can on its own, because the person using it may
/// not know what a step is for: it shows the library from the last launch
/// straight away, refreshes it in the background, opens Amazon's sign-in once
/// if that refresh finds nobody signed in, and exports a book as soon as it is
/// clicked, queueing any further clicks behind it.
///
/// There is one Amazon session (one web view), so sign-in, the library refresh
/// and exports take turns through `busy`, as serve.ts's do over the Chrome
/// profile.
@MainActor
public final class AppModel {
  /// Real ASINs are ten characters; the bound keeps junk out of paths and logs.
  public static let asinPattern = #"^[A-Z0-9]{1,20}$"#
  /// Books waiting or exporting at once; nobody queues 500 books attended.
  public static let maxQueuedBooks = 50
  /// Finished books kept in the queue for their outcome; the files themselves
  /// are found by scanning the output folder.
  public static let maxFinishedBooks = 100
  public static let maxLogEntries = 250

  enum RefreshOutcome { case ok, signedOut, error }

  public private(set) var amazon: AmazonState = .unknown
  public private(set) var busy: AppBusy?
  public private(set) var library: LibraryState?
  public private(set) var libraryError: String?
  public private(set) var amazonError: String?
  public private(set) var diskBooks: [BookStatus] = []
  public private(set) var alsoPdf = false
  public private(set) var books: [BookJob] = []
  /// Stop was pressed; the book being exported is the last one.
  public private(set) var stopRequested = false
  public private(set) var log: [QueueLogEntry] = []

  /// Amazon's sign-in page comes up by itself at most once per launch. A
  /// second automatic sign-in after the person cancelled the first would feel
  /// like the app fighting them; from then on the page offers a button.
  public private(set) var autoSignInUsed = false
  /// A refresh came due while an export held the session; run it afterwards.
  private var refreshAfterQueue = false
  private var disposed = false

  /// Called with the state JSON (what serve.ts streams on /api/events),
  /// coalesced over `environment.broadcastDelay`.
  public var onStateChange: ((String) -> Void)?
  private var broadcastScheduled = false

  public let environment: AppEnvironment
  private let backend: AppBackend
  private let scanner: DiskScanner

  public init(backend: AppBackend, environment: AppEnvironment) {
    self.backend = backend
    self.environment = environment
    scanner = DiskScanner()
  }

  /// Show what is already known — the cached library, the books on disk — and
  /// start finding out the rest in the background (serve.ts `init`).
  public func start() async {
    alsoPdf = AppConfig.load(environment.configURL).alsoPdf == true

    if let cached = LibraryCache.read(from: environment.libraryCacheDir) {
      library = LibraryState(books: cached.books, fetchedAt: cached.fetchedAt, fromCache: true)
    }

    await refreshDiskBooks()
    broadcast()
    startLibraryRefresh()
  }

  public func dispose() {
    disposed = true
  }

  // MARK: - state

  /// serve.ts `uiState()`. Fields that are `undefined` there are left out
  /// here too; `busy` is `null` when idle, as there.
  var uiState: OrderedJSON {
    .object([
      ("platform", .string("darwin")),
      ("outDir", .string(environment.outDir.standardizedFileURL.path)),
      // No OpenAI in the app: Vision reads the pages, so there is never a key
      // to ask for.
      ("hasApiKey", .bool(false)),
      ("localOcr", .bool(true)),
      ("needsApiKey", .bool(false)),
      ("alsoPdf", .bool(alsoPdf)),
      ("amazon", .string(amazon.rawValue)),
      ("busy", busy.map { .string($0.rawValue) } ?? .null),
      ("library", library?.orderedJSON),
      ("libraryError", libraryError.map { .string($0) }),
      // The app has no Chrome profile another process could hold.
      ("profileBusy", .bool(false)),
      ("amazonError", amazonError.map { .string($0) }),
      ("diskBooks", .array(diskBooks.map(\.orderedJSON))),
      (
        "queue",
        .object([
          ("books", .array(books.map(\.orderedJSON))),
          ("stopRequested", .bool(stopRequested)),
          ("log", .array(log.map(\.orderedJSON))),
        ])
      ),
    ])
  }

  public var stateJSON: String { uiState.serialized(pretty: false) }

  func refreshDiskBooks() async {
    diskBooks = await scanner.scan(outDir: environment.outDir)
  }

  /// Tell the page, at most once per `broadcastDelay`.
  func broadcast() {
    guard !broadcastScheduled, !disposed else { return }
    broadcastScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + environment.broadcastDelay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.broadcastScheduled = false
        guard !self.disposed else { return }
        self.onStateChange?(self.stateJSON)
      }
    }
  }

  private func queueLog(_ level: QueueLogEntry.Level, _ asin: String, _ message: String) {
    log.append(QueueLogEntry(time: Self.now(), level: level, message: "[\(asin)] \(message)"))
    if log.count > Self.maxLogEntries {
      log.removeFirst(log.count - Self.maxLogEntries)
    }
  }

  static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded(.down) }

  // MARK: - routing

  /// One request from the page: `method` and `path` as the HTTP call would
  /// have them (the path may carry a query), `body` the parsed JSON (or a
  /// JSON string). Replies with serve.ts's status and body.
  public func handle(method: String, path: String, body: Any?) async -> AppResponse {
    do {
      guard let components = URLComponents(string: "http://localhost" + path) else {
        throw AppHTTPError(404, "not found")
      }
      let pathname = components.percentEncodedPath
      let route = "\(method.uppercased()) \(pathname)"

      switch route {
      case "GET /api/state":
        if components.queryItems?.contains(where: { $0.name == "scan" }) == true {
          await refreshDiskBooks()
        }
        return AppResponse(200, uiState)

      case "POST /api/config":
        try handleConfig(try parseBody(body))
        return AppResponse(200, uiState)

      case "POST /api/login":
        try startLogin()
        return AppResponse(202, uiState)

      case "POST /api/signout":
        try await signOut()
        return AppResponse(200, uiState)

      case "POST /api/library":
        if busy == .export {
          throw AppHTTPError(
            409, "Your books are being exported — the list can refresh once that is done.")
        }
        if busy == .login {
          throw AppHTTPError(409, "Finish signing in to Amazon first.")
        }
        startLibraryRefresh()
        return AppResponse(202, uiState)

      case "POST /api/export":
        try enqueue(try parseBody(body))
        return AppResponse(202, uiState)

      case "POST /api/queue/remove":
        try removeFromQueue(try parseBody(body))
        return AppResponse(200, uiState)

      case "POST /api/queue/stop":
        stopQueue()
        return AppResponse(200, uiState)

      case "POST /api/reveal":
        try handleReveal(try parseBody(body))
        return AppResponse(200, .object([]))

      default:
        if method.uppercased() == "GET", pathname.hasPrefix("/api/download/") {
          let saved = try handleDownload(pathname)
          return AppResponse(200, .object([("saved", .string(saved.path))]))
        }
        throw AppHTTPError(404, "not found")
      }
    } catch let error as AppHTTPError {
      return AppResponse(error.status, .object([("error", .string(error.message))]))
    } catch {
      return AppResponse(500, .object([("error", .string(describeError(error)))]))
    }
  }

  /// The body as serve.ts `readBody` gives it: nothing is `{}`, a string is
  /// parsed as JSON.
  private func parseBody(_ body: Any?) throws -> Any {
    guard let body, !(body is NSNull) else { return [String: Any]() }
    if let text = body as? String {
      if text.isEmpty { return [String: Any]() }
      guard
        let value = try? JSONSerialization.jsonObject(
          with: Data(text.utf8), options: [.fragmentsAllowed])
      else { throw AppHTTPError(400, "invalid JSON body") }
      return value
    }
    return body
  }

  // MARK: - validation

  static func isValidAsin(_ value: String) -> Bool {
    value.range(of: asinPattern, options: .regularExpression) != nil
  }

  /// serve.ts `parseAsin`.
  static func parseAsin(_ value: Any?) throws -> String {
    if let string = value as? String, isValidAsin(string) { return string }
    throw AppHTTPError(400, "invalid ASIN: \(String(jsString(value).prefix(40)))")
  }

  /// JavaScript's `String(value)`, near enough for an error message.
  private static func jsString(_ value: Any?) -> String {
    switch value {
    case nil: return "undefined"
    case is NSNull: return "null"
    case let string as String: return string
    case let number as NSNumber:
      return AppConfig.isBool(number) ? (number.boolValue ? "true" : "false") : number.stringValue
    case let array as [Any]: return array.map { jsString($0) }.joined(separator: ",")
    default: return "[object Object]"
    }
  }

  static func isTrue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, AppConfig.isBool(number) else { return false }
    return number.boolValue
  }

  public struct ExportRequest: Equatable {
    public var asin: String
    /// `nil` means "the usual": Markdown, plus PDF where the settings say so.
    public var formats: [ExportFormat]?
    /// Throw the existing page images away and read the book again.
    public var forceCapture: Bool
  }

  /// serve.ts `parseExportRequest`: every rejection happens before anything
  /// is queued.
  static func parseExportRequest(_ body: Any) throws -> ExportRequest {
    guard let object = body as? [String: Any] else {
      throw AppHTTPError(400, "expected a JSON object")
    }
    let asin = try parseAsin(object["asin"])

    var formats: [ExportFormat]?
    if let raw = object["formats"] {
      guard let list = raw as? [Any] else { throw AppHTTPError(400, "formats must be a list") }
      var unique: [ExportFormat] = []
      for item in list {
        guard let name = item as? String, let format = ExportFormat(rawValue: name),
          !unique.contains(format)
        else { continue }
        unique.append(format)
      }
      if unique.isEmpty { throw AppHTTPError(400, "no known format requested") }
      formats = unique
    }

    // Re-capturing a book costs an hour, so it happens only when the page
    // asked for it in so many words.
    return ExportRequest(asin: asin, formats: formats, forceCapture: isTrue(object["forceCapture"]))
  }

  // MARK: - handlers

  private func handleConfig(_ body: Any) throws {
    // Only the PDF preference is accepted: there is no API key in the app,
    // and a `model` is never the page's to choose.
    let object = body as? [String: Any]
    guard let number = object?["alsoPdf"] as? NSNumber, AppConfig.isBool(number) else {
      broadcast()
      return
    }
    let value = number.boolValue
    try AppConfig.save(alsoPdf: value, to: environment.configURL)
    alsoPdf = value
    broadcast()
  }

  // MARK: - amazon & library

  /// Forget the Amazon account: its session, and the library list that
  /// belongs to it. The person lands on the signed-out notice with its "Sign
  /// in to Amazon" button rather than on the sign-in page: signing out is as
  /// likely to be about leaving as about switching accounts.
  private func signOut() async throws {
    if busy == .export {
      throw AppHTTPError(409, "An export is running — sign out once it has finished.")
    }
    if busy != nil {
      throw AppHTTPError(409, "Kindle Export is busy with Amazon — try again in a moment")
    }

    busy = .login
    broadcast()
    await backend.signOut()
    try? FileManager.default.removeItem(at: LibraryCache.path(in: environment.libraryCacheDir))
    library = nil
    libraryError = nil
    amazonError = nil
    amazon = .signedOut
    // Signing out is deliberate; the sign-in page shouldn't reopen by itself.
    autoSignInUsed = true
    busy = nil
    broadcast()
  }

  private func startLogin() throws {
    if busy == .export {
      throw AppHTTPError(409, "an export is running — wait for it to finish")
    }
    if busy != nil {
      throw AppHTTPError(409, "Kindle Export is busy with Amazon — try again in a moment")
    }
    runLogin()
  }

  /// Refresh the library with the reader, out of sight.
  ///
  /// Skipped while an export runs: the export has the session, and books
  /// clicked meanwhile shouldn't wait behind a refresh they didn't ask for. A
  /// refresh already under way is simply joined.
  func startLibraryRefresh() {
    if disposed || busy == .library { return }
    if busy != nil {
      refreshAfterQueue = true
      return
    }

    busy = .library
    broadcast()

    Task { @MainActor in
      var signInNext = false
      let outcome = await fetchLibraryOnce()
      // The first "not signed in" of this launch opens Amazon's sign-in by
      // itself: the person may not know that is the step they are missing.
      if outcome == .signedOut, !autoSignInUsed {
        autoSignInUsed = true
        signInNext = !disposed
      }
      if signInNext {
        // Straight from one task into the next, so a book clicked in the
        // meantime can't grab the session in between.
        runLogin()
      } else {
        releaseSession()
      }
    }
  }

  /// Show Amazon's sign-in page (in the main window), and once Amazon
  /// confirms the session, read the library with it. Assumes the caller checked the session is free.
  private func runLogin() {
    let before = amazon
    autoSignInUsed = true
    busy = .login
    amazon = .signingIn
    amazonError = nil
    broadcast()

    Task { @MainActor in
      let confirmed = await backend.signIn()
      if !confirmed || disposed {
        // Cancelling is an answer, not a new fact about the session:
        // whatever was known before still holds.
        amazon = before == .signingIn ? .unknown : before
        releaseSession()
        return
      }

      amazon = .signedIn
      busy = .library
      broadcast()
      _ = await fetchLibraryOnce()
      releaseSession()
    }
  }

  /// One library read, recorded in the state. Never throws: every failure
  /// becomes something the page can show.
  func fetchLibraryOnce() async -> RefreshOutcome {
    libraryError = nil
    do {
      let books = try await backend.fetchLibrary()
      let fetchedAt = Self.now()
      library = LibraryState(books: books, fetchedAt: fetchedAt, fromCache: false)
      amazon = .signedIn
      LibraryCache.write(
        LibraryCache.Cached(books: books, fetchedAt: fetchedAt), to: environment.libraryCacheDir)
      return .ok
    } catch LibraryService.LibraryError.notSignedIn {
      amazon = .signedOut
      return .signedOut
    } catch {
      libraryError = describeError(error)
      return .error
    }
  }

  /// A session task ended; hand the session to whatever is waiting for it.
  private func releaseSession() {
    busy = nil
    broadcast()
    pump()
  }

  // MARK: - queue

  private func enqueue(_ body: Any) throws {
    let request = try Self.parseExportRequest(body)

    // A second click on a book that is already waiting or exporting is the
    // same request again, not a second export.
    if books.contains(where: { $0.asin == request.asin && !$0.status.isFinished }) { return }

    let pending = books.filter { !$0.status.isFinished }.count
    if pending >= Self.maxQueuedBooks {
      throw AppHTTPError(400, "at most \(Self.maxQueuedBooks) books can wait at once")
    }

    // Asking for a finished book again replaces its old outcome.
    books.removeAll { $0.asin == request.asin }
    books.append(
      BookJob(
        asin: request.asin, title: titleFor(request.asin),
        formats: request.formats ?? formatsFor(request.asin),
        forceCapture: request.forceCapture, queuedAt: Self.now()))

    // Stop already cleared everything that was waiting; a book clicked after
    // it is a fresh request and should run once the current one is done.
    stopRequested = false

    let finished = books.filter { $0.status.isFinished }
    if finished.count > Self.maxFinishedBooks {
      let drop = Set(finished.prefix(finished.count - Self.maxFinishedBooks).map(ObjectIdentifier.init))
      books.removeAll { drop.contains(ObjectIdentifier($0)) }
    }

    broadcast()
    pump()
  }

  private func removeFromQueue(_ body: Any) throws {
    let asin = try Self.parseAsin((body as? [String: Any])?["asin"])
    guard let book = books.first(where: { $0.asin == asin && !$0.status.isFinished }) else {
      throw AppHTTPError(404, "that book is not waiting to export")
    }
    if book.status != .queued {
      throw AppHTTPError(409, "that book is already being exported — use Stop to end after it")
    }
    books.removeAll { $0 === book }
    broadcast()
  }

  /// "Stop after this book": everything still waiting comes off the queue now,
  /// and the book being exported finishes — cutting a capture off mid-book
  /// would only leave a truncated book that needs capturing again.
  private func stopQueue() {
    let before = books.count
    books.removeAll { $0.status == .queued }
    let active = books.contains { !$0.status.isFinished }
    if active { stopRequested = true }
    if active || books.count != before { broadcast() }
  }

  /// Markdown always; PDF when the settings ask, or the book already has one.
  private func formatsFor(_ asin: String) -> [ExportFormat] {
    let hasPdf =
      diskBooks.first { $0.asin == asin }?.exports.contains { $0.format == .pdf } ?? false
    return alsoPdf || hasPdf ? [.md, .pdf] : [.md]
  }

  private func titleFor(_ asin: String) -> String {
    library?.books.first { $0.asin == asin }?.title
      ?? diskBooks.first { $0.asin == asin }?.title
      ?? asin
  }

  /// Start exporting if a book is waiting and the session is free. Called
  /// whenever either might have changed.
  private func pump() {
    if disposed || busy != nil { return }

    if !books.contains(where: { $0.status == .queued }) {
      if refreshAfterQueue {
        refreshAfterQueue = false
        startLibraryRefresh()
      }
      return
    }

    busy = .export
    broadcast()
    Task { @MainActor in await runQueue() }
  }

  private func runQueue() async {
    while !disposed, let book = books.first(where: { $0.status == .queued }) {
      await exportBook(book)
    }
    stopRequested = false
    releaseSession()
  }

  private func exportBook(_ book: BookJob) async {
    book.status = .working
    broadcast()

    // Settings may have changed since launch; the stored config is what the
    // settings screen writes, so read it fresh per book.
    let stored = AppConfig.load(environment.configURL)
    let options = BookPipeline.Options(
      command: .all, formats: book.formats,
      // A re-capture throws the pages away and reads the book from the start —
      // the only way out of a capture that stopped early.
      forceCapture: book.forceCapture, forceOcr: false,
      concurrency: stored.concurrency ?? VisionOCR.defaultConcurrency)

    do {
      let result = try await backend.processBook(asin: book.asin, options: options) {
        [weak self, book] event in
        self?.onBookEvent(book, event)
      }
      book.outputs = result.outputs.map(\.lastPathComponent)
      // The same verdict the CLI's exit status uses.
      book.status = result.fellShort(options.command) ? .warning : .done
    } catch {
      book.status = .failed
      book.error = describeError(error)
      queueLog(.warn, book.asin, "failed: \(book.error ?? "")")
    }

    book.finishedAt = Self.now()
    await refreshDiskBooks()
    broadcast()
  }

  func onBookEvent(_ book: BookJob, _ event: PipelineEvent) {
    // An event delivered after the book's outcome is settled must not undo it.
    if book.status.isFinished { return }
    switch event {
    case .stage(let stage):
      switch stage {
      case .capture: book.status = .capturing
      case .transcribe: book.status = .transcribing
      case .export: book.status = .exporting
      }
    case .captureProgress(let captured, let page, let total):
      book.captured = captured
      book.capturedPage = page
      book.capturedTotal = total
    case .transcribeProgress(let done, let total):
      book.transcribed = done
      book.transcribedTotal = total
    case .info(let message):
      queueLog(.info, book.asin, message)
    case .warn(let message):
      book.warnings.append(message)
      queueLog(.warn, book.asin, message)
    }
    broadcast()
  }

  // MARK: - files

  private func handleReveal(_ body: Any) throws {
    let asin = (body as? [String: Any])?["asin"] as? String ?? ""
    if !asin.isEmpty, !Self.isValidAsin(asin) { throw AppHTTPError(400, "invalid ASIN") }

    let dir =
      asin.isEmpty
      ? environment.outDir : environment.outDir.appendingPathComponent(asin, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
      throw AppHTTPError(404, "no such folder")
    }
    environment.openFolder(dir)
  }

  /// `GET /api/download/<asin>/<name>`: in a browser this streams the file;
  /// in the app the file is copied to Downloads under a name that overwrites
  /// nothing, and shown in Finder. Validation is serve.ts's.
  func handleDownload(_ pathname: String) throws -> URL {
    let parts = pathname.components(separatedBy: "/").dropFirst(3)  // ['', 'api', 'download', ...]
    guard parts.count == 2 else { throw AppHTTPError(400, "bad download path") }

    guard let asin = parts.first!.removingPercentEncoding,
      let name = parts.last!.removingPercentEncoding
    else { throw AppHTTPError(400, "bad download path") }

    guard Self.isValidAsin(asin) else { throw AppHTTPError(400, "invalid ASIN") }
    // The name comes back from the page, so treat it as hostile: no
    // separators, no traversal, only the two formats we ever write.
    guard !name.contains("/"), !name.contains("\\"), !name.contains(".."),
      name.hasSuffix(".md") || name.hasSuffix(".pdf")
    else { throw AppHTTPError(400, "invalid file name") }

    let bookDir = environment.outDir.appendingPathComponent(asin, isDirectory: true)
      .standardizedFileURL
    let file = bookDir.appendingPathComponent(name).standardizedFileURL
    guard file.deletingLastPathComponent().path == bookDir.path else {
      throw AppHTTPError(400, "invalid file name")
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { throw AppHTTPError(404, "file not found") }

    let target = try Self.copyIntoFolder(file, name: name, folder: environment.downloadsDir)
    environment.revealFile(target)
    return target
  }

  /// Copy without overwriting anything: a second download of the same book
  /// becomes `name 2.md`, as Safari does.
  static func copyIntoFolder(_ source: URL, name: String, folder: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var target = folder.appendingPathComponent(name)
    var n = 2
    while true {
      do {
        try fm.copyItem(at: source, to: target)
        return target
      } catch CocoaError.fileWriteFileExists {
        target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        n += 1
        if n > 10_000 { throw AppHTTPError(500, "could not find a free file name") }
      }
    }
  }
}

/// The disk scan (book-status.ts `scanBooks`) off the main thread, with its
/// own KindleCore.
actor DiskScanner {
  private var core: PipelineCore?

  func scan(outDir: URL) -> [BookStatus] {
    if core == nil { core = try? PipelineCore() }
    guard let core else { return [] }
    return BookScanner.scanBooks(outDir: outDir, core: core)
  }
}
