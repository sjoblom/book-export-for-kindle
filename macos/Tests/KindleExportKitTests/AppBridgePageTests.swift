import Foundation
import WebKit
import XCTest

@testable import KindleExportKit

/// The real page (dist-core/app.html, built by `pnpm build:app-page`) against
/// the real bridge and model, with Amazon and the pipeline stood in for: the
/// contract in PLAN.md exercised from both ends.
@MainActor
final class AppBridgePageTests: XCTestCase {
  var root: URL!
  var model: AppModel!
  var backend: FakeBackend!
  var bridge: Bridge!
  var webView: WKWebView!

  override func setUp() async throws {
    guard JSCore.locateScript() != nil else {
      throw XCTSkip("dist-core/kindle-core.js not built — run `pnpm build:core`")
    }
    guard let page = AppPage.locate() else {
      throw XCTSkip("dist-core/app.html not built — run `pnpm build:app-page`")
    }

    root = try PipelineFixtures.tempDir("bridge")
    let outDir = root.appendingPathComponent("books", isDirectory: true)
    let bookDir = outDir.appendingPathComponent("B00TEST", isDirectory: true)
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    try Data("hello book".utf8).write(to: bookDir.appendingPathComponent("the-book.md"))

    backend = FakeBackend()
    model = AppModel(
      backend: backend,
      environment: AppEnvironment(
        outDir: outDir, configURL: root.appendingPathComponent("config.json"),
        libraryCacheDir: root.appendingPathComponent("support"),
        downloadsDir: root.appendingPathComponent("Downloads"),
        openFolder: { _ in }, revealFile: { _ in }, broadcastDelay: 0.01))
    bridge = Bridge(model: model)
    model.onStateChange = { [weak self] in self?.bridge.pushState($0) }

    let configuration = WKWebViewConfiguration()
    bridge.install(on: configuration)
    webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
    bridge.attach(webView)
    webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

    await model.start()
    try await waitFor("the page to load") { [webView] in
      (try? await webView!.evaluateJavaScript("typeof window.__kindleReply")) as? String == "function"
    }
  }

  override func tearDown() async throws {
    backend?.releaseAll()
    model?.dispose()
    webView = nil
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
      if Date() > deadline {
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// Run `body` (an async function body) in the page and return its value.
  func page(_ body: String) async throws -> Any? {
    try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
  }

  func testRequestsRoundTripThroughTheBridge() async throws {
    let platform = try await page("return await request('GET', '/api/state').then(s => s.platform)")
    XCTAssertEqual(platform as? String, "darwin")

    // Errors come back as rejections carrying serve.ts's message.
    let error = try await page(
      "return await api('/api/export', {asin: '../x'}).then(() => 'ok', e => e.message)")
    XCTAssertEqual(error as? String, "invalid ASIN: ../x")

    let queued = try await page(
      "return await api('/api/export', {asin: 'B00TEST'}).then(s => s.queue.books[0].asin)")
    XCTAssertEqual(queued as? String, "B00TEST")
    try await waitFor("the export") { self.backend.calls.count == 1 }
  }

  func testStatePushesReachThePage() async throws {
    try await waitFor("the library refresh") { self.model.busy == nil }
    // The library the refresh read is rendered from the pushed state.
    try await waitFor("the library to render") {
      let text = try? await self.page("return document.body.innerText")
      return (text as? String)?.contains("Another Book") == true
    }

    backend.holdBooks = true
    _ = await model.handle(method: "POST", path: "/api/export", body: ["asin": "B00TEST"])
    try await waitFor("the pushed state to show the export") {
      let busy = try? await self.page("return typeof state === 'object' && state ? state.busy : null")
      return busy as? String == "export"
    }
  }

  func testDownloadsGoThroughTheBridge() async throws {
    let saved = try await page(
      "return await request('GET', downloadPath('B00TEST', 'the-book.md')).then(r => r.saved)")
    let path = try XCTUnwrap(saved as? String)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "hello book")
  }
}
