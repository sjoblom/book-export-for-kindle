import AppKit
import Foundation
import WebKit

/// The Kindle Cloud Reader in a `WKWebView`, and the few ways of driving it
/// that the reader actually accepts.
///
/// What a spike established (see ../../../PLAN.md): page images arrive through
/// a `URL.createObjectURL` hook, render TARs through a `fetch`/XHR hook, and
/// the reader only reacts to *trusted* input — `element.click()` from script
/// does nothing on its chevrons — so clicks and key presses are synthesized
/// `NSEvent`s sent through the window, which works while it is minimized.
///
/// This class is deliberately thin: it knows about web views, events and
/// hooks, not about books. `CaptureEngine` does the reading.
@MainActor
public final class ReaderSession: NSObject {
  public enum Key: Equatable, Sendable {
    case arrowRight, arrowLeft, enter, escape, backspace
    case character(Character)
  }

  public struct SessionError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
  }

  /// A network response the hooks copied out (already filtered to the three
  /// kinds the capture wants).
  public enum NetworkCapture: Sendable {
    case render(RenderFiles)
    case startReading(String)
    case yjMetadata(String)
  }

  public static let safariUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  /// The viewport extractBook uses (Playwright `viewport`).
  public static let viewportSize = NSSize(width: 1280, height: 720)

  public let webView: WKWebView
  public let window: NSWindow

  /// Image blobs waiting to become the page image's `src`.
  public let blobs = BlobStore()
  /// Render TARs for `asin`, in arrival order.
  public private(set) var renders: [RenderFiles] = []
  /// The latest `startReading` response body for `asin`.
  public private(set) var startReadingJSON: String?
  /// The first `YJmetadata.jsonp` body naming `asin`.
  public private(set) var yjMetadataText: String?

  /// Only responses for this book are kept (the reader also fetches metadata
  /// for recommendations). Set before loading the reader.
  public var asin: String?

  /// Diagnostics.
  public var log: ((String) -> Void)?
  /// Called with each network capture as it lands.
  public var onNetworkCapture: ((NetworkCapture) -> Void)?

  /// Run every `interceptInterval` inside `waitFor` — the stand-in for
  /// Playwright's locator handler (the capture uses it to answer the "Most
  /// Recent Page Read" dialog whenever it turns up).
  public var interceptor: (() async -> Void)?
  public var interceptInterval: TimeInterval = 0.5
  private var intercepting = false
  private var lastIntercept = Date.distantPast

  private let clientWorld = WKContentWorld.world(name: "KindleExport")
  private var eventNumber = 0
  public private(set) var webContentProcessTerminated = false

  /// - Parameter window: a window to host the reader in; one is created
  ///   (1280×720, not yet shown) when nil. Its content view is replaced.
  public init(window: NSWindow? = nil) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let controller = configuration.userContentController
    controller.addUserScript(
      WKUserScript(
        source: ReaderScripts.hooks, injectionTime: .atDocumentStart, forMainFrameOnly: false,
        in: .page))
    controller.addUserScript(
      WKUserScript(
        source: ReaderScripts.helpers, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: clientWorld))

    webView = WKWebView(
      frame: NSRect(origin: .zero, size: ReaderSession.viewportSize), configuration: configuration)
    webView.customUserAgent = ReaderSession.safariUserAgent
    if #available(macOS 13.3, *) { webView.isInspectable = true }

    self.window =
      window
      ?? NSWindow(
        contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: ReaderSession.viewportSize),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
    super.init()

    let proxy = WeakMessageHandler(self)
    controller.add(proxy, contentWorld: .page, name: ReaderScripts.blobHandler)
    controller.add(proxy, contentWorld: .page, name: ReaderScripts.netHandler)
    webView.navigationDelegate = self

    self.window.isReleasedWhenClosed = false
    self.window.acceptsMouseMovedEvents = true
    self.window.title = "Kindle"
    self.window.contentView = webView

    installContentBlocker()
  }

  // MARK: - window

  /// Bring the window forward — for signing in.
  public func show() {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Park the window in the Dock so nobody clicks into a running capture.
  public func minimize() {
    if !window.isVisible { window.orderFront(nil) }
    window.miniaturize(nil)
  }

  // MARK: - navigation

  public var currentURL: URL? { webView.url }

  /// Amazon's sign-in (and its challenge pages) live under `/ap/`.
  public var isOnSignIn: Bool {
    webView.url?.path.contains("/ap/signin") == true
  }

  /// Load `url` and wait until loading finishes, or a sign-in page shows up
  /// instead (the redirect for an expired session), or `timeout` passes.
  public func load(_ url: URL, timeout: TimeInterval = 30) async throws {
    webContentProcessTerminated = false
    webView.load(URLRequest(url: url))
    let deadline = Date().addingTimeInterval(timeout)
    // `isLoading` flips on asynchronously; don't mistake "not started yet"
    // for "finished".
    try await Task.sleep(nanoseconds: 200_000_000)
    while webView.isLoading, !isOnSignIn {
      if Date() > deadline {
        log?("loading \(url.absoluteString) timed out; continuing")
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  /// Wait (with the window visible — the caller's job) for the person to get
  /// through Amazon's sign-in, i.e. for the URL to leave `/ap/`.
  public func waitForSignIn(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while webView.url?.path.hasPrefix("/ap/") == true || webView.url == nil {
      if Date() > deadline { throw SessionError(message: "sign-in was not completed in time") }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
  }

  // MARK: - script

  /// Run an expression in the page world; returns what WebKit bridges
  /// (`nil` for undefined/null or on error).
  public func evaluate(_ javaScript: String) async -> Any? {
    await withCheckedContinuation { continuation in
      webView.evaluateJavaScript(javaScript) { value, _ in
        continuation.resume(returning: value is NSNull ? nil : value)
      }
    }
  }

  /// Run one of the `ReaderScripts` bodies in the client world and decode its
  /// JSON result. `nil` when the body returned null or evaluation failed (a
  /// navigation in flight, a crashed content process) — every caller treats
  /// "can't tell" as its safe default.
  func run<T: Decodable>(
    _ body: String, _ arguments: [String: Any] = [:], as _: T.Type = T.self,
    timeout: TimeInterval = 15
  ) async -> T? {
    let json: String? = await withCheckedContinuation { continuation in
      var finished = false
      let finish: (String?) -> Void = { value in
        if finished { return }
        finished = true
        continuation.resume(returning: value)
      }
      webView.callAsyncJavaScript(
        body, arguments: arguments, in: nil, in: clientWorld
      ) { result in
        MainActor.assumeIsolated {
          if case .success(let value) = result { finish(value as? String) } else { finish(nil) }
        }
      }
      // A content process that has hung never calls back.
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        MainActor.assumeIsolated { finish(nil) }
      }
    }
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  nonisolated static func specArgument(_ spec: ElementSpec) -> Any {
    let data = (try? JSONEncoder().encode(spec)) ?? Data("{}".utf8)
    return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
  }

  /// Poll `condition` every `interval` until it holds or `timeout` passes.
  /// The interceptor runs along the way. Throws only on cancellation.
  public func waitFor(
    timeout: TimeInterval, interval: TimeInterval = 0.1,
    _ condition: () async -> Bool
  ) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      try Task.checkCancellation()
      if await condition() { return true }
      if Date() >= deadline { return false }
      await runInterceptor()
      try await Task.sleep(nanoseconds: UInt64(interval * 1e9))
    }
  }

  /// Wait for a (visible) element matching `spec`.
  public func waitFor(_ spec: ElementSpec, timeout: TimeInterval) async throws -> Bool {
    try await waitFor(timeout: timeout, interval: 0.1) { await self.exists(spec) }
  }

  func runInterceptor() async {
    guard let interceptor, !intercepting,
      Date().timeIntervalSince(lastIntercept) >= interceptInterval
    else { return }
    intercepting = true
    lastIntercept = Date()
    await interceptor()
    intercepting = false
  }

  // MARK: - queries

  public func exists(_ spec: ElementSpec) async -> Bool {
    await run(ReaderScripts.exists, ["spec": Self.specArgument(spec)], as: Bool.self) ?? false
  }

  public func count(_ selector: String) async -> Int? {
    await run(ReaderScripts.count, ["selector": selector], as: Int.self)
  }

  public func imageSource(_ selector: String) async -> String? {
    await run(ReaderScripts.imageSource, ["selector": selector], as: String?.self) ?? nil
  }

  public func textContent(_ selector: String) async -> String? {
    await run(ReaderScripts.textContent, ["selector": selector], as: String?.self) ?? nil
  }

  struct ElementCenter: Decodable {
    var x: Double
    var y: Double
    var hit: Bool?
    var kind: String?
  }

  func center(of spec: ElementSpec) async -> ElementCenter? {
    await run(ReaderScripts.elementCenter, ["spec": Self.specArgument(spec)], as: ElementCenter.self)
  }

  // MARK: - input

  /// Click the element's centre with real mouse events, waiting up to
  /// `timeout` for it to appear. Returns whether there was anything to click.
  @discardableResult
  public func click(_ spec: ElementSpec, timeout: TimeInterval = 5) async throws -> Bool {
    var target: ElementCenter?
    _ = try await waitFor(timeout: timeout) {
      target = await self.center(of: spec)
      return target != nil
    }
    guard let target else { return false }
    if target.hit == false {
      log?("clicking \(spec.selector): something else is on top of it")
    }
    click(css: CGPoint(x: target.x, y: target.y))
    return true
  }

  /// Mouse down + up at a CSS-pixel point in the viewport.
  public func click(css point: CGPoint) {
    let location = windowLocation(css: point)
    send(mouse: .mouseMoved, at: location)
    send(mouse: .leftMouseDown, at: location)
    send(mouse: .leftMouseUp, at: location)
  }

  /// Move the mouse over the element (Playwright `hover`).
  public func hover(_ spec: ElementSpec) async {
    guard let target = await center(of: spec) else { return }
    let location = windowLocation(css: CGPoint(x: target.x, y: target.y))
    send(mouse: .mouseMoved, at: location)
  }

  func windowLocation(css point: CGPoint) -> CGPoint {
    CaptureSupport.windowPoint(
      css: point, webViewFrameInWindow: webView.convert(webView.bounds, to: nil),
      zoom: webView.pageZoom * webView.magnification)
  }

  private func send(mouse type: NSEvent.EventType, at location: CGPoint) {
    eventNumber += 1
    let event: NSEvent?
    if type == .mouseMoved {
      event = NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: eventNumber, clickCount: 0, pressure: 0)
    } else {
      event = NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: eventNumber, clickCount: 1,
        pressure: type == .leftMouseDown ? 1 : 0)
    }
    guard let event else { return }
    if type == .mouseMoved {
      // A window only routes mouse-moved events to the view under the cursor
      // when it tracks them; handing it straight to the web view is reliable.
      webView.mouseMoved(with: event)
    } else {
      window.sendEvent(event)
    }
  }

  /// Key down + up, delivered to the web view.
  public func press(_ key: Key) {
    window.makeFirstResponder(webView)
    let (keyCode, characters, flags) = ReaderSession.keyEventFields(key)
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      if let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
      {
        window.sendEvent(event)
      }
    }
  }

  /// Type `text` as key presses (digits for the Go to Page field).
  public func type(_ text: String) async throws {
    for character in text {
      press(.character(character))
      try await Task.sleep(nanoseconds: 30_000_000)
    }
  }

  nonisolated static func keyEventFields(_ key: Key) -> (UInt16, String, NSEvent.ModifierFlags) {
    func function(_ scalar: Int) -> String { String(UnicodeScalar(UInt16(scalar))!) }
    switch key {
    case .arrowRight: return (124, function(NSRightArrowFunctionKey), [.numericPad, .function])
    case .arrowLeft: return (123, function(NSLeftArrowFunctionKey), [.numericPad, .function])
    case .enter: return (36, "\r", [])
    case .escape: return (53, "\u{1b}", [])
    case .backspace: return (51, "\u{7f}", [])
    case .character(let c):
      // ANSI key codes, for `event.code`; the characters are what get typed.
      let codes: [Character: UInt16] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
      ]
      return (codes[c] ?? 0, String(c), [])
    }
  }

  // MARK: - content blocking

  /// Block Amazon's analytics requests, as extractBook's `page.route` does —
  /// not needed, but it's what an ad blocker would do and it's faster.
  private func installContentBlocker() {
    let rules = """
      [
        {"trigger": {"url-filter": "unagi-[a-z0-9_]+\\\\.amazon\\\\.com", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}},
        {"trigger": {"url-filter": "m\\\\.media-amazon\\\\.com.*/showads", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}},
        {"trigger": {"url-filter": "fls-na\\\\.amazon\\\\.com.*/remote-weblab-triggers", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}}
      ]
      """
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "KindleExportBlocklist", encodedContentRuleList: rules
    ) { [weak self] list, error in
      MainActor.assumeIsolated {
        if let list {
          self?.webView.configuration.userContentController.add(list)
        } else if let error {
          self?.log?("content blocker not installed: \(error.localizedDescription)")
        }
      }
    }
  }

  // MARK: - messages from the hooks

  fileprivate func receive(_ message: WKScriptMessage) {
    guard let body = message.body as? [String: Any] else { return }
    switch message.name {
    case ReaderScripts.blobHandler:
      guard let url = body["url"] as? String, let dataURL = body["data"] as? String,
        let data = ReaderSession.decodeDataURL(dataURL)
      else { return }
      blobs.insert(url: url, type: body["type"] as? String ?? "", data: data)

    case ReaderScripts.netHandler:
      guard let urlString = body["url"] as? String, let dataURL = body["data"] as? String,
        let data = ReaderSession.decodeDataURL(dataURL)
      else { return }
      let status = (body["status"] as? NSNumber)?.intValue ?? 0
      handleNetwork(url: urlString, status: status, body: data)

    default:
      break
    }
  }

  /// The filtering extractBook's `page.on('response')` handler does.
  func handleNetwork(url urlString: String, status: Int, body: Data) {
    guard status == 200 else { return }

    if urlString.hasPrefix("jsonp:") || URL(string: urlString)?.path.hasSuffix("YJmetadata.jsonp") == true {
      let text = String(decoding: body, as: UTF8.self)
      guard yjMetadataText == nil, ReaderSession.jsonpNames(asin: asin, text) else { return }
      yjMetadataText = text
      onNetworkCapture?(.yjMetadata(text))
      return
    }

    guard let components = URLComponents(string: urlString),
      components.host == "read.amazon.com",
      let asin,
      components.queryItems?.first(where: { $0.name == "asin" })?.value?.lowercased()
        == asin.lowercased()
    else { return }

    switch components.path {
    case "/service/mobile/reader/startReading":
      let text = String(decoding: body, as: UTF8.self)
      startReadingJSON = text
      onNetworkCapture?(.startReading(text))
    case "/renderer/render":
      do {
        if let files = try RenderFiles(tar: body) {
          renders.append(files)
          onNetworkCapture?(.render(files))
        }
      } catch {
        log?("could not read a render TAR (\(body.count) bytes): \(error)")
      }
    default:
      break
    }
  }

  /// Whether a JSONP payload is about `asin` (extractBook ignores metadata
  /// for other books, which the reader also loads).
  nonisolated static func jsonpNames(asin: String?, _ text: String) -> Bool {
    guard let asin else { return true }
    guard let object = parseJSONP(text) else { return false }
    return (object["asin"] as? String) == asin
  }

  /// utils.ts `parseJsonpResponse`: the object between the outer parens.
  nonisolated static func parseJSONP(_ text: String) -> [String: Any]? {
    // Same pattern as JSONP_REGEX (`.` doesn't cross newlines there either).
    guard let regex = try? NSRegularExpression(pattern: #"\((\{.*\})\)"#),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(text[range].utf8))) as? [String: Any]
  }

  nonisolated static func decodeDataURL(_ dataURL: String) -> Data? {
    guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
    let header = dataURL[..<comma]
    let payload = dataURL[dataURL.index(after: comma)...]
    if header.hasSuffix(";base64") { return Data(base64Encoded: String(payload)) }
    return String(payload).removingPercentEncoding.map { Data($0.utf8) }
  }

  /// Reset what was captured from the network (a fresh reader load).
  public func clearCaptures() {
    blobs.removeAll()
    renders.removeAll()
    startReadingJSON = nil
    yjMetadataText = nil
  }

  /// Fetch `YJmetadata.jsonp` ourselves, with the web view's cookies, when
  /// the page loaded it in a way no hook saw (a `<script>` tag with a callback
  /// we didn't anticipate). Best effort.
  public func fetchYJMetadataFallback() async {
    guard yjMetadataText == nil,
      let urls = await run(ReaderScripts.yjMetadataResources, as: [String].self),
      !urls.isEmpty
    else { return }
    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    for urlString in urls {
      guard let url = URL(string: urlString) else { continue }
      var request = URLRequest(url: url)
      request.setValue(ReaderSession.safariUserAgent, forHTTPHeaderField: "User-Agent")
      for (name, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { cookie in
        url.host.map { $0.hasSuffix(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) } ?? false
      }) {
        request.setValue(value, forHTTPHeaderField: name)
      }
      guard let (data, response) = try? await URLSession.shared.data(for: request),
        let http = response as? HTTPURLResponse
      else { continue }
      handleNetwork(url: urlString, status: http.statusCode, body: data)
      if yjMetadataText != nil { return }
    }
  }
}

extension ReaderSession: WKNavigationDelegate {
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webContentProcessTerminated = true
    log?("the reader's web content process terminated")
  }
}

/// `WKUserContentController` retains its handlers; this keeps it from
/// retaining the session.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var session: ReaderSession?
  init(_ session: ReaderSession) { self.session = session }

  func userContentController(
    _: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    MainActor.assumeIsolated { session?.receive(message) }
  }
}
