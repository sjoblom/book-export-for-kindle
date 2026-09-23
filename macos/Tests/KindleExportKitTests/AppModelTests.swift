import Foundation
import XCTest

@testable import KindleExportKit

/// Amazon, the reader window and the pipeline, stood in for — the same seams
/// serve.test.ts mocks (fetchLibrary, interactiveLogin, processBook).
/// Everything around them — validation, the queue, the state — is AppModel's
/// own code.
@MainActor
final class FakeBackend: AppBackend {
  enum Outcome {
    case books([LibraryBook])
    case signedOut
    case failure(String)
  }

  var libraryReads = 0
  var logins = 0
  var signOuts = 0
  var loginConfirms = true
  /// Outcomes for the next library reads, in order; then `fallback`.
  var outcomes: [Outcome] = []
  var fallback: Outcome = .books(AppModelTests.library)
  var holdLibrary = false
  private var libraryWaiters: [CheckedContinuation<Void, Never>] = []

  struct Call {
    var asin: String
    var options: BookPipeline.Options
  }

  var calls: [Call] = []
  var holdBooks = false
  private var bookWaiters: [CheckedContinuation<Void, Never>] = []
  /// Events each book emits before finishing.
  var events: [PipelineEvent] = []
  /// Thrown by the next book instead of a result.
  var failNext: String?
  var fellShortNext = false

  var libraryWaiting: Bool { !libraryWaiters.isEmpty }
  var bookWaiting: Bool { !bookWaiters.isEmpty }

  func releaseLibrary() {
    if !libraryWaiters.isEmpty { libraryWaiters.removeFirst().resume() }
  }

  func releaseBook() {
    if !bookWaiters.isEmpty { bookWaiters.removeFirst().resume() }
  }

  func releaseAll() {
    holdLibrary = false
    holdBooks = false
    while libraryWaiting { releaseLibrary() }
    while bookWaiting { releaseBook() }
  }

  func fetchLibrary() async throws -> [LibraryBook] {
    libraryReads += 1
    if holdLibrary {
      await withCheckedContinuation { libraryWaiters.append($0) }
    }
    let outcome = outcomes.isEmpty ? fallback : outcomes.removeFirst()
    switch outcome {
    case .books(let books): return books
    case .signedOut: throw LibraryService.LibraryError.notSignedIn
    case .failure(let message): throw LibraryService.LibraryError.requestFailed(message)
    }
  }

  func signOut() async { signOuts += 1 }

  func signIn() async -> Bool {
    logins += 1
    return loginConfirms
  }

  func processBook(
    asin: String, options: BookPipeline.Options,
    emit: @escaping @MainActor @Sendable (PipelineEvent) -> Void
  ) async throws -> BookResult {
    calls.append(Call(asin: asin, options: options))
    if holdBooks {
      await withCheckedContinuation { bookWaiters.append($0) }
    }
    for event in events { emit(event) }
    if let message = failNext {
      failNext = nil
      throw CaptureEngine.CaptureError.failed(message)
    }
    let short = fellShortNext
    fellShortNext = false
    return BookResult(
      asin: asin, outputs: [URL(fileURLWithPath: "/x/\(asin)/book.md")],
      completeness: BookCompleteness(
        complete: !short, capturedPages: 1, transcribedPages: short ? 0 : 1,
        missingPages: short ? [MissingPage(index: 0, page: 1)] : [], captureStoppedEarly: false,
        remedy: nil, summary: nil, warnings: []),
      failedPages: [], duration: 0.001)
  }
}

@MainActor
final class AppModelTests: XCTestCase {
  static let library = [
    LibraryBook(
      asin: "B00TEST", title: "The Test Book", authors: ["Ann Author"],
      coverUrl: "https://m.media-amazon.com/images/I/test.jpg"),
    LibraryBook(asin: "B00OTHER", title: "Another Book", authors: []),
  ]

  /// serve.ts `uiState()`, key for key. `library`, `libraryError` and
  /// `amazonError` are `undefined` (left out) until they have a value.
  static let stateKeys = [
    "platform", "outDir", "hasApiKey", "localOcr", "needsApiKey", "alsoPdf", "amazon", "busy",
    "library", "libraryError", "profileBusy", "amazonError", "diskBooks", "queue",
  ]
  static let optionalStateKeys: Set<String> = ["library", "libraryError", "amazonError"]

  var root: URL!
  var outDir: URL!
  var environment: AppEnvironment!
  var backend: FakeBackend!
  var model: AppModel!
  var opened: [URL] = []
  var revealed: [URL] = []

  override func setUp() async throws {
    guard JSCore.locateScript() != nil else {
      throw XCTSkip("dist-core/kindle-core.js not built — run `pnpm build:core`")
    }
    root = try PipelineFixtures.tempDir("app")
    outDir = root.appendingPathComponent("books", isDirectory: true)
    let bookDir = outDir.appendingPathComponent("B00TEST", isDirectory: true)
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    try Data("hello book".utf8).write(to: bookDir.appendingPathComponent("the-book.md"))
    try Data("not downloadable".utf8).write(to: bookDir.appendingPathComponent("notes.txt"))
    // A file outside the book folder that a traversal would reach.
    try Data("should stay put".utf8).write(to: outDir.appendingPathComponent("secret.md"))

    opened = []
    revealed = []
    environment = AppEnvironment(
      outDir: outDir,
      configURL: root.appendingPathComponent("config/config.json"),
      libraryCacheDir: root.appendingPathComponent("support", isDirectory: true),
      downloadsDir: root.appendingPathComponent("Downloads", isDirectory: true),
      openFolder: { [weak self] in self?.opened.append($0) },
      revealFile: { [weak self] in self?.revealed.append($0) },
      broadcastDelay: 0.01)
    backend = FakeBackend()
    model = try await launch()
  }

  override func tearDown() async throws {
    backend?.releaseAll()
    model?.dispose()
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  /// A fresh app on the same folders (a second launch).
  func launch() async throws -> AppModel {
    let model = AppModel(backend: backend, environment: environment)
    await model.start()
    return model
  }

  // MARK: helpers

  @discardableResult
  func request(
    _ method: String, _ path: String, _ body: Any? = nil, on model: AppModel? = nil
  ) async -> (status: Int, body: [String: Any]) {
    let response = await (model ?? self.model).handle(method: method, path: path, body: body)
    return (response.status, response.object as? [String: Any] ?? [:])
  }

  func post(_ path: String, _ body: Any? = [String: Any](), on model: AppModel? = nil) async -> Int {
    await request("POST", path, body, on: model).status
  }

  func state(_ model: AppModel? = nil) async -> [String: Any] {
    await request("GET", "/api/state", on: model).body
  }

  /// Wait for something the model runs towards, rather than a fixed delay.
  func until(
    _ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline {
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// XCTAssert's arguments are autoclosures, which can't `await`; these take
  /// values, so `await assertEqual(post(...), 202)` works.
  func assertEqual<T: Equatable>(
    _ value: T, _ expected: T, _ message: String = "", file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(value, expected, message, file: file, line: line)
  }

  func assertNil(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, file: file, line: line)
  }

  /// Wait until nothing holds the session: no refresh, sign-in or export.
  func idle(_ model: AppModel? = nil) async throws {
    let model = model ?? self.model!
    try await until("the session to be free") { model.busy == nil }
  }

  func queued(_ model: AppModel? = nil) -> [String] {
    (model ?? self.model).books.map { "\($0.asin):\($0.status.rawValue)" }
  }

  // MARK: - state

  func testStateHasServeTsShape() async throws {
    try await idle()
    let state = await state()

    // Every key serve.ts sends, and nothing it doesn't.
    let keys = Set(state.keys)
    XCTAssertTrue(keys.isSubset(of: Set(Self.stateKeys)), "extra keys: \(keys.subtracting(Self.stateKeys))")
    XCTAssertEqual(
      Set(Self.stateKeys).subtracting(Self.optionalStateKeys).subtracting(keys), [],
      "missing keys")
    XCTAssertEqual(keys, Set(Self.stateKeys).subtracting(["libraryError", "amazonError"]))

    // Key order as uiState() writes it (what JSON.stringify would produce).
    let json = model.stateJSON
    let positions = Self.stateKeys.compactMap { json.range(of: "\"\($0)\":")?.lowerBound }
    XCTAssertEqual(positions, positions.sorted())

    XCTAssertEqual(state["platform"] as? String, "darwin")
    XCTAssertEqual(state["outDir"] as? String, outDir.standardizedFileURL.path)
    XCTAssertEqual(state["hasApiKey"] as? Bool, false)
    XCTAssertEqual(state["localOcr"] as? Bool, true)
    XCTAssertEqual(state["needsApiKey"] as? Bool, false)
    XCTAssertEqual(state["alsoPdf"] as? Bool, false)
    XCTAssertEqual(state["profileBusy"] as? Bool, false)
    XCTAssertTrue(state["busy"] is NSNull, "busy is null when idle, not absent")
    XCTAssertNil(state["model"])

    let queue = try XCTUnwrap(state["queue"] as? [String: Any])
    XCTAssertEqual((queue["books"] as? [Any])?.count, 0)
    XCTAssertEqual(queue["stopRequested"] as? Bool, false)
    XCTAssertEqual((queue["log"] as? [Any])?.count, 0)

    let disk = try XCTUnwrap(state["diskBooks"] as? [[String: Any]])
    XCTAssertEqual(disk.map { $0["asin"] as? String }, ["B00TEST"])
    let exports = try XCTUnwrap(disk[0]["exports"] as? [[String: Any]])
    XCTAssertEqual(exports.map { $0["name"] as? String }, ["the-book.md"])
    XCTAssertEqual(exports[0]["format"] as? String, "md")
    XCTAssertNotNil(disk[0]["completeness"] as? [String: Any])
  }

  func testQueueEntryShape() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the book to start") { backend.bookWaiting }

    let queue = await state()["queue"] as? [String: Any]
    let book = try XCTUnwrap((queue?["books"] as? [[String: Any]])?.first)
    XCTAssertEqual(book["asin"] as? String, "B00TEST")
    XCTAssertEqual(book["title"] as? String, "The Test Book")
    XCTAssertEqual(book["status"] as? String, "working")
    XCTAssertEqual(book["formats"] as? [String], ["md"])
    XCTAssertEqual(book["forceCapture"] as? Bool, false)
    XCTAssertNotNil(book["queuedAt"] as? Double)
    XCTAssertEqual(book["warnings"] as? [String], [])
    XCTAssertEqual(book["outputs"] as? [String], [])
    XCTAssertNil(book["error"])
    XCTAssertNil(book["finishedAt"])
  }

  func testStateWithScanRereadsTheDisk() async throws {
    try await idle()
    let other = outDir.appendingPathComponent("B00NEW", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: other.appendingPathComponent("new.md"))

    let before = await state()["diskBooks"] as? [[String: Any]]
    XCTAssertEqual(before?.count, 1)
    let after = await request("GET", "/api/state?scan=1").body["diskBooks"] as? [[String: Any]]
    XCTAssertEqual(after?.map { $0["asin"] as? String }, ["B00NEW", "B00TEST"])
  }

  func testUnknownRoutesAre404() async throws {
    let unknown = await request("GET", "/api/nope")
    XCTAssertEqual(unknown.status, 404)
    XCTAssertEqual(unknown.body["error"] as? String, "not found")
    await assertEqual(request("POST", "/api/state").status, 404)
    await assertEqual(request("GET", "/api/export").status, 404)
  }

  func testStatePushesAreCoalesced() async throws {
    try await idle()
    var pushes: [String] = []
    model.onStateChange = { pushes.append($0) }

    for asin in ["B00A", "B00B", "B00C"] {
      backend.holdBooks = true
      _ = await post("/api/export", ["asin": asin])
    }
    try await until("a state push") { !pushes.isEmpty }
    try await Task.sleep(nanoseconds: 50_000_000)
    // Three enqueues, a start and a status change, coalesced.
    XCTAssertLessThanOrEqual(pushes.count, 2)
    let pushed = try JSONSerialization.jsonObject(with: Data(pushes[0].utf8)) as? [String: Any]
    XCTAssertEqual(pushed?["busy"] as? String, "export")
  }

  // MARK: - export requests

  func testValidatesExportRequestsBeforeQueueing() async throws {
    try await idle()
    let bodies: [Any?] = [
      [String: Any](),
      ["asin": ""],
      ["asin": "b00!bad"],
      ["asin": "../escape"],
      ["asin": ["B00TEST"]],
      ["asins": ["B00TEST"]],
      ["asin": String(repeating: "A", count: 21)],
      ["asin": 12345],
      ["asin": "B00TEST", "formats": "pdf"],
      ["asin": "B00TEST", "formats": ["docx"]],
      ["asin": "B00TEST", "formats": NSNull()],
      "not json",
      [1, 2],
    ]
    for body in bodies {
      let status = await post("/api/export", body)
      XCTAssertEqual(status, 400, "\(String(describing: body))")
    }
    XCTAssertEqual(backend.calls.count, 0)
    XCTAssertEqual(model.books.count, 0)

    let invalid = await request("POST", "/api/export", ["asin": "../escape"])
    XCTAssertEqual(invalid.body["error"] as? String, "invalid ASIN: ../escape")
  }

  func testParsesExportRequests() throws {
    XCTAssertEqual(
      try AppModel.parseExportRequest(["asin": "B00TEST", "formats": ["pdf", "md", "pdf", "x"]]),
      AppModel.ExportRequest(asin: "B00TEST", formats: [.pdf, .md], forceCapture: false))
    // Only a real `true` asks for a re-capture.
    XCTAssertTrue(try AppModel.parseExportRequest(["asin": "B1", "forceCapture": true]).forceCapture)
    XCTAssertFalse(try AppModel.parseExportRequest(["asin": "B1", "forceCapture": 1]).forceCapture)
    XCTAssertFalse(try AppModel.parseExportRequest(["asin": "B1", "forceCapture": "true"]).forceCapture)
    XCTAssertNil(try AppModel.parseExportRequest(["asin": "B1"]).formats)
  }

  func testAcceptsABodySentAsAJSONString() async throws {
    try await idle()
    await assertEqual(post("/api/export", #"{"asin":"B00TEST"}"#), 202)
    try await until("the book to be processed") { backend.calls.count == 1 }
    await assertEqual(post("/api/export", "{nope"), 400)
  }

  func testResumesRatherThanRecapturesForAnOrdinaryExport() async throws {
    try await idle()
    await assertEqual(post("/api/export", ["asin": "B00TEST"]), 202)
    try await until("the book to be processed") { backend.calls.count == 1 }
    let options = backend.calls[0].options
    XCTAssertEqual(options.command, .all)
    XCTAssertFalse(options.forceCapture)
    XCTAssertFalse(options.forceOcr)
    XCTAssertEqual(options.formats, [.md])

    try await idle()
    XCTAssertEqual(queued(), ["B00TEST:done"])
    XCTAssertEqual(model.books[0].title, "The Test Book")
    XCTAssertEqual(model.books[0].outputs, ["book.md"])
    XCTAssertNotNil(model.books[0].finishedAt)
  }

  func testCapturesAgainWhenThePageAsks() async throws {
    try await idle()
    backend.holdBooks = true
    await assertEqual(post("/api/export", ["asin": "B00TEST", "forceCapture": true]), 202)
    try await until("the book to be processed") { backend.calls.count == 1 }
    XCTAssertTrue(backend.calls[0].options.forceCapture)
    XCTAssertTrue(model.books[0].forceCapture)
  }

  func testAlsoPdfIsSavedKeepingOtherSettingsAndUsed() async throws {
    try await idle()
    let configURL = environment.configURL
    try FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"openaiApiKey":"sk-old","outDir":"books","concurrency":3}"#.utf8).write(to: configURL)

    let response = await request("POST", "/api/config", ["alsoPdf": true, "model": "gpt-x", "apiKey": "sk-new"])
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["alsoPdf"] as? Bool, true)
    XCTAssertNil(response.body["model"])

    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
    XCTAssertEqual(stored?["alsoPdf"] as? Bool, true)
    XCTAssertEqual(stored?["openaiApiKey"] as? String, "sk-old", "the key is not the app's to change")
    XCTAssertEqual(stored?["outDir"] as? String, "books")
    XCTAssertNil(stored?["model"])
    let permissions = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)

    await assertEqual(post("/api/export", ["asin": "B00TEST"]), 202)
    try await until("the book to be processed") { backend.calls.count == 1 }
    XCTAssertEqual(backend.calls[0].options.formats, [.md, .pdf])
    // Stored settings are read per book.
    XCTAssertEqual(backend.calls[0].options.concurrency, 3)

    // A setting that isn't a boolean changes nothing.
    await assertEqual(post("/api/config", ["alsoPdf": "no"]), 200)
    XCTAssertTrue(model.alsoPdf)
    // And the setting is there on the next launch.
    let next = try await launch()
    defer { next.dispose() }
    XCTAssertTrue(next.alsoPdf)
  }

  // MARK: - pipeline events

  func testBookEventsBecomeQueueState() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the book to start") { backend.bookWaiting }
    let book = model.books[0]

    model.onBookEvent(book, .stage(.capture))
    XCTAssertEqual(book.status, .capturing)
    model.onBookEvent(book, .captureProgress(captured: 12, page: 10, total: 200))
    XCTAssertEqual([book.captured, book.capturedPage, book.capturedTotal], [12, 10, 200])
    model.onBookEvent(book, .stage(.transcribe))
    XCTAssertEqual(book.status, .transcribing)
    model.onBookEvent(book, .transcribeProgress(done: 3, total: 12))
    XCTAssertEqual([book.transcribed, book.transcribedTotal], [3, 12])
    model.onBookEvent(book, .stage(.export))
    XCTAssertEqual(book.status, .exporting)
    model.onBookEvent(book, .info("capture: 12 page images"))
    model.onBookEvent(book, .warn("2 pages could not be read"))
    XCTAssertEqual(book.warnings, ["2 pages could not be read"])
    XCTAssertEqual(
      model.log.map { "\($0.level.rawValue) \($0.message)" },
      ["info [B00TEST] capture: 12 page images", "warn [B00TEST] 2 pages could not be read"])

    backend.releaseBook()
    try await idle()
    XCTAssertEqual(book.status, .done)
    // A late event can't undo a settled outcome.
    model.onBookEvent(book, .stage(.export))
    XCTAssertEqual(book.status, .done)
  }

  func testFailuresAndShortBooksAreReported() async throws {
    try await idle()
    backend.failNext = "the reader did not load"
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await idle()
    try await until("the book to finish") { model.books.first?.status.isFinished == true }
    XCTAssertEqual(queued(), ["B00TEST:failed"])
    XCTAssertEqual(model.books[0].error, "the reader did not load")
    XCTAssertEqual(model.log.last?.message, "[B00TEST] failed: the reader did not load")

    backend.fellShortNext = true
    _ = await post("/api/export", ["asin": "B00OTHER"])
    try await until("the book to finish") { model.books.last?.status.isFinished == true }
    XCTAssertEqual(queued(), ["B00TEST:failed", "B00OTHER:warning"])
  }

  // MARK: - queue

  func testQueuesBooksClickedWhileOneIsExportingAndRunsThemInOrder() async throws {
    try await idle()
    backend.holdBooks = true
    await assertEqual(post("/api/export", ["asin": "B00TEST"]), 202)
    try await until("the first book to start") { backend.calls.count == 1 }

    // One reader, one book at a time: the second click waits.
    await assertEqual(post("/api/export", ["asin": "B00OTHER"]), 202)
    XCTAssertEqual(queued(), ["B00TEST:working", "B00OTHER:queued"])
    XCTAssertEqual(model.busy, .export)
    await assertEqual(state()["busy"] as? String, "export")
    XCTAssertEqual(backend.calls.count, 1)

    backend.releaseBook()
    try await until("the second book to start") { backend.calls.count == 2 }
    XCTAssertEqual(backend.calls.map(\.asin), ["B00TEST", "B00OTHER"])

    backend.releaseBook()
    try await idle()
    XCTAssertEqual(queued(), ["B00TEST:done", "B00OTHER:done"])
  }

  func testDoesNotQueueABookTwice() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the first book to start") { backend.calls.count == 1 }
    _ = await post("/api/export", ["asin": "B00OTHER"])

    for asin in ["B00OTHER", "B00TEST"] {
      await assertEqual(post("/api/export", ["asin": asin]), 202)
    }
    XCTAssertEqual(queued(), ["B00TEST:working", "B00OTHER:queued"])
  }

  func testExportsAFinishedBookAgainReplacingItsOutcome() async throws {
    try await idle()
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the first export") { backend.calls.count == 1 }
    try await idle()

    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the second export") { backend.calls.count == 2 }
    try await idle()
    XCTAssertEqual(queued(), ["B00TEST:done"])
  }

  func testRemovesAWaitingBookButNotTheOneBeingExported() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the first book to start") { backend.calls.count == 1 }
    _ = await post("/api/export", ["asin": "B00OTHER"])

    await assertEqual(post("/api/queue/remove", ["asin": "B00OTHER"]), 200)
    XCTAssertEqual(queued(), ["B00TEST:working"])

    await assertEqual(post("/api/queue/remove", ["asin": "B00TEST"]), 409)
    await assertEqual(post("/api/queue/remove", ["asin": "B00NONE"]), 404)
    await assertEqual(post("/api/queue/remove", ["asin": "../x"]), 400)

    backend.releaseBook()
    try await idle()
    XCTAssertEqual(backend.calls.map(\.asin), ["B00TEST"])
  }

  func testStopsAfterTheCurrentBookAndRunsBooksClickedAfterThat() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the first book to start") { backend.calls.count == 1 }
    _ = await post("/api/export", ["asin": "B00OTHER"])
    _ = await post("/api/export", ["asin": "B00THIRD"])

    await assertEqual(post("/api/queue/stop"), 200)
    XCTAssertTrue(model.stopRequested)
    XCTAssertEqual(queued(), ["B00TEST:working"])
    let stopState = await state()["queue"] as? [String: Any]
    XCTAssertEqual(stopState?["stopRequested"] as? Bool, true)

    // A book clicked after Stop is a new request, not one Stop cancelled.
    _ = await post("/api/export", ["asin": "B00FOURTH"])
    XCTAssertFalse(model.stopRequested)

    backend.releaseBook()
    try await until("the next book to start") { backend.calls.count == 2 }
    backend.releaseBook()
    try await idle()
    XCTAssertEqual(backend.calls.map(\.asin), ["B00TEST", "B00FOURTH"])
    XCTAssertFalse(model.stopRequested)
  }

  func testStopWithNothingRunningChangesNothing() async throws {
    try await idle()
    await assertEqual(post("/api/queue/stop"), 200)
    XCTAssertFalse(model.stopRequested)
  }

  func testCapsHowManyBooksCanWait() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the first book to start") { backend.calls.count == 1 }

    for i in 1..<50 {
      let asin = "B" + String(format: "%09d", i)
      await assertEqual(post("/api/export", ["asin": asin]), 202)
    }
    let over = await request("POST", "/api/export", ["asin": "B999999999"])
    XCTAssertEqual(over.status, 400)
    XCTAssertEqual(over.body["error"] as? String, "at most 50 books can wait at once")
    XCTAssertEqual(model.books.count, 50)
  }

  func testRefusesToRefreshTheLibraryOrSignInWhileExporting() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the book to start") { backend.calls.count == 1 }

    let reads = backend.libraryReads
    let refresh = await request("POST", "/api/library")
    XCTAssertEqual(refresh.status, 409)
    XCTAssertEqual(
      refresh.body["error"] as? String,
      "Your books are being exported — the list can refresh once that is done.")
    XCTAssertEqual(backend.libraryReads, reads)

    await assertEqual(post("/api/login"), 409)
    XCTAssertEqual(backend.logins, 0)
  }

  func testSignOutForgetsTheSessionAndTheLibraryWithoutReopeningSignIn() async throws {
    try await idle()
    XCTAssertNotNil(LibraryCache.read(from: environment.libraryCacheDir))
    let logins = backend.logins

    let reply = await request("POST", "/api/signout")
    XCTAssertEqual(reply.status, 200)
    XCTAssertEqual(backend.signOuts, 1)
    XCTAssertEqual(model.amazon, .signedOut)
    XCTAssertNil(model.library)
    XCTAssertNil(model.busy)
    // The list belonged to the account that just left.
    XCTAssertNil(LibraryCache.read(from: environment.libraryCacheDir))
    // Deliberate, so the sign-in page stays closed until asked for.
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(backend.logins, logins)
    XCTAssertEqual(reply.body["amazon"] as? String, "signed-out")
  }

  func testRefusesToSignOutWhileExporting() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the book to start") { backend.calls.count == 1 }

    await assertEqual(post("/api/signout"), 409)
    XCTAssertEqual(backend.signOuts, 0)
  }

  // MARK: - start-up, library and sign-in

  func testReadsTheLibraryInTheBackgroundAtLaunchAndCachesIt() async throws {
    try await idle()
    XCTAssertEqual(backend.libraryReads, 1)
    XCTAssertEqual(model.amazon, .signedIn)
    let current = await state()
    let library = try XCTUnwrap(current["library"] as? [String: Any])
    XCTAssertEqual(library["fromCache"] as? Bool, false)
    let books = try XCTUnwrap(library["books"] as? [[String: Any]])
    XCTAssertEqual(books.map { $0["asin"] as? String }, ["B00TEST", "B00OTHER"])
    XCTAssertEqual(books[0]["coverUrl"] as? String, Self.library[0].coverUrl)

    // ... and keeps it for the next launch.
    let cached = try XCTUnwrap(LibraryCache.read(from: environment.libraryCacheDir))
    XCTAssertEqual(cached.books.map(\.asin), ["B00TEST", "B00OTHER"])
  }

  func testShowsTheCachedLibraryStraightAwayWhileItRefreshes() async throws {
    try await idle()
    try Data(
      #"""
      {"version":1,"fetchedAt":1234,"books":[
        {"asin":"B00CACHED","title":"From Last Time","authors":["Someone"],"coverUrl":"https://m.media-amazon.com/images/I/c.jpg"},
        {"asin":"B00EVIL","title":"Bad Cover","authors":[],"coverUrl":"javascript:alert(1)"},
        {"asin":"../nope","title":"Bad ASIN","authors":[]}
      ]}
      """#.utf8
    ).write(to: LibraryCache.path(in: environment.libraryCacheDir))

    backend.holdLibrary = true
    let second = try await launch()
    defer { second.dispose() }
    XCTAssertEqual(second.busy, .library)
    let current = await state(second)
    let library = try XCTUnwrap(current["library"] as? [String: Any])
    XCTAssertEqual(library["fetchedAt"] as? Double, 1234)
    XCTAssertEqual(library["fromCache"] as? Bool, true)
    let books = try XCTUnwrap(library["books"] as? [[String: Any]])
    XCTAssertEqual(books.map { $0["asin"] as? String }, ["B00CACHED", "B00EVIL"])
    XCTAssertNil(books[1]["coverUrl"])

    try await until("the refresh to start") { backend.libraryWaiting }
    backend.releaseLibrary()
    try await idle(second)
    XCTAssertEqual(second.library?.fromCache, false)
    XCTAssertEqual(second.library?.books.map(\.asin), ["B00TEST", "B00OTHER"])
  }

  func testOpensSignInOnceWhenNobodyIsSignedInThenReadsTheLibrary() async throws {
    try await idle()
    backend.outcomes = [.signedOut, .books(Self.library)]
    backend.loginConfirms = true

    let second = try await launch()
    defer { second.dispose() }
    try await idle(second)
    XCTAssertEqual(backend.logins, 1)
    XCTAssertEqual(second.amazon, .signedIn)
    XCTAssertEqual(second.library?.books.count, 2)
    XCTAssertTrue(second.autoSignInUsed)
  }

  func testDoesNotOpenSignInByItselfASecondTime() async throws {
    try await idle()
    backend.fallback = .signedOut
    backend.loginConfirms = false  // the person closed the window

    let second = try await launch()
    defer { second.dispose() }
    try await idle(second)
    XCTAssertEqual(backend.logins, 1)
    XCTAssertEqual(second.amazon, .signedOut)

    // A refresh by hand still finds nobody signed in, and now the page offers
    // the button instead of the app reopening the window.
    let reads = backend.libraryReads
    await assertEqual(post("/api/library", on: second), 202)
    try await idle(second)
    XCTAssertEqual(backend.libraryReads, reads + 1)
    XCTAssertEqual(backend.logins, 1)
    XCTAssertEqual(second.amazon, .signedOut)

    // The button itself always works.
    backend.loginConfirms = true
    backend.fallback = .books(Self.library)
    await assertEqual(post("/api/login", on: second), 202)
    try await idle(second)
    XCTAssertEqual(backend.logins, 2)
    XCTAssertEqual(second.amazon, .signedIn)
  }

  func testShowsSigningInWhileTheWindowIsOpen() async throws {
    try await idle()
    backend.loginConfirms = true
    await assertEqual(post("/api/login"), 202)
    // Straight away, before the sign-in task has run.
    XCTAssertEqual(model.amazon, .signingIn)
    XCTAssertEqual(model.busy, .login)
    // A second sign-in or a refresh has to wait for this one.
    await assertEqual(post("/api/login"), 409)
    await assertEqual(post("/api/library"), 409)
    try await idle()
    XCTAssertEqual(model.amazon, .signedIn)
  }

  func testReportsALibraryErrorWithoutSigningIn() async throws {
    try await idle()
    backend.fallback = .failure("503 Service Unavailable")
    let second = try await launch()
    defer { second.dispose() }
    try await idle(second)
    XCTAssertEqual(backend.logins, 0)
    await assertEqual(
      state(second)["libraryError"] as? String,
      "Kindle library request failed: 503 Service Unavailable")

    backend.fallback = .books(Self.library)
    _ = await post("/api/library", on: second)
    try await idle(second)
    await assertNil(state(second)["libraryError"])
  }

  func testStartsABookClickedDuringTheFirstLibraryLoadOnceTheLoadIsDone() async throws {
    try await idle()
    backend.holdLibrary = true
    let second = try await launch()
    defer { second.dispose() }
    try await until("the refresh to start") { backend.libraryWaiting }

    await assertEqual(post("/api/export", ["asin": "B00TEST"], on: second), 202)
    XCTAssertEqual(queued(second), ["B00TEST:queued"])
    XCTAssertEqual(backend.calls.count, 0)

    backend.releaseLibrary()
    try await until("the export to start") { backend.calls.count == 1 }
    try await idle(second)
    XCTAssertEqual(queued(second), ["B00TEST:done"])
  }

  func testARefreshAskedForDuringAnExportRunsAfterIt() async throws {
    try await idle()
    backend.holdBooks = true
    _ = await post("/api/export", ["asin": "B00TEST"])
    try await until("the book to start") { backend.calls.count == 1 }
    let reads = backend.libraryReads
    model.startLibraryRefresh()  // what a due retry does
    XCTAssertEqual(backend.libraryReads, reads)

    backend.releaseBook()
    try await until("the deferred refresh") { backend.libraryReads == reads + 1 }
    try await idle()
  }

  // MARK: - files

  func testDownloadCopiesToDownloadsWithoutOverwriting() async throws {
    let first = await request("GET", "/api/download/B00TEST/the-book.md")
    XCTAssertEqual(first.status, 200)
    let saved = try XCTUnwrap(first.body["saved"] as? String)
    XCTAssertEqual(URL(fileURLWithPath: saved).lastPathComponent, "the-book.md")
    XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "hello book")

    let second = await request("GET", "/api/download/B00TEST/the-book.md")
    XCTAssertEqual(
      (second.body["saved"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
      "the-book 2.md")
    XCTAssertEqual(revealed.map(\.lastPathComponent), ["the-book.md", "the-book 2.md"])
    // The export itself stays where it was.
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: outDir.appendingPathComponent("B00TEST/the-book.md").path))
  }

  func testDownloadsAFileWhoseNameIsNotLatin1() async throws {
    let name = "日本語.md"
    try Data("hello book".utf8).write(to: outDir.appendingPathComponent("B00TEST/\(name)"))
    let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let response = await request("GET", "/api/download/B00TEST/\(encoded)")
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual((response.body["saved"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }, name)
  }

  func testRefusesDownloadPathsThatLeaveTheBookFolder() async throws {
    await assertEqual(request("GET", "/api/download/B00TEST/..%2Fsecret.md").status, 400)
    await assertEqual(request("GET", "/api/download/B00TEST/notes.txt").status, 400)
    await assertEqual(request("GET", "/api/download/b00%2F../x.md").status, 400)
    await assertEqual(request("GET", "/api/download/B00TEST/a%5Cb.md").status, 400)
    await assertEqual(request("GET", "/api/download/B00TEST").status, 400)
    await assertEqual(request("GET", "/api/download/B00TEST/x/y.md").status, 400)
    let absent = await request("GET", "/api/download/B00TEST/absent.md")
    XCTAssertEqual(absent.status, 404)
    XCTAssertEqual(absent.body["error"] as? String, "file not found")
    XCTAssertEqual(revealed, [])
    let downloads = (try? FileManager.default.contentsOfDirectory(atPath: environment.downloadsDir.path)) ?? []
    XCTAssertEqual(downloads, [])
  }

  func testRevealOpensTheBookOrTheBooksFolder() async throws {
    let book = await request("POST", "/api/reveal", ["asin": "B00TEST"])
    XCTAssertEqual(book.status, 200)
    XCTAssertEqual(book.body.count, 0)
    await assertEqual(post("/api/reveal", [String: Any]()), 200)
    XCTAssertEqual(
      opened.map(\.standardizedFileURL.path),
      [outDir.appendingPathComponent("B00TEST").standardizedFileURL.path, outDir.standardizedFileURL.path])

    await assertEqual(post("/api/reveal", ["asin": "../x"]), 400)
    await assertEqual(post("/api/reveal", ["asin": "B00NONE"]), 404)
    XCTAssertEqual(opened.count, 2)
  }
}

/// The transport's encoding, and the sign-in URL rule.
@MainActor
final class AppBridgeTests: XCTestCase {
  func testParsesRequestsFromThePage() throws {
    let request = try XCTUnwrap(
      Bridge.parse(["id": 7, "method": "POST", "path": "/api/export", "body": ["asin": "B00TEST"]]))
    XCTAssertEqual(request.id as? Int, 7)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/api/export")
    XCTAssertEqual((request.body as? [String: Any])?["asin"] as? String, "B00TEST")

    XCTAssertNil(Bridge.parse("nope"))
    XCTAssertNil(Bridge.parse(["method": "GET"]))
    XCTAssertNil(Bridge.parse(["method": "GET", "path": "https://evil.example/"]))
  }

  func testEncodesRepliesAsJavaScriptLiterals() {
    XCTAssertEqual(Bridge.idLiteral(7), "7")
    XCTAssertEqual(Bridge.idLiteral(1.5), "1.5")
    XCTAssertEqual(Bridge.idLiteral("r-1\"</script>"), #""r-1\"</script>""#)
    XCTAssertEqual(Bridge.idLiteral(true), "null")
    XCTAssertEqual(Bridge.idLiteral(nil), "null")
    XCTAssertEqual(Bridge.idLiteral(["x"]), "null")
    // Valid JSON, but line terminators inside a string literal in older JS.
    XCTAssertEqual(Bridge.jsLiteral(json: "\"a\u{2028}b\u{2029}\""), "\"a\\u2028b\\u2029\"")
  }

  func testSignedInUrlsMatchSessionTs() {
    let yes = ["https://read.amazon.com/kindle-library", "https://read.amazon.com/?asin=B00TEST"]
    let no = [
      "http://read.amazon.com/kindle-library",
      "https://www.amazon.com/ap/signin?openid.return_to=https://read.amazon.com",
      "https://read.amazon.com/ap/signin",
      "https://read.amazon.com/gp/signin/x",
      "https://read.amazon.com.evil.example/kindle-library",
      // Where a session without cookies is sent: the reader's own domain.
      "https://read.amazon.com/landing",
    ]
    for url in yes { XCTAssertTrue(NativeBackend.isSignedInUrl(URL(string: url)), url) }
    for url in no { XCTAssertFalse(NativeBackend.isSignedInUrl(URL(string: url)), url) }
    XCTAssertFalse(NativeBackend.isSignedInUrl(nil))
  }
}
