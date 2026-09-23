import Foundation
import WebKit

/// The page ↔ Swift transport (PLAN.md "Page ↔ Swift bridge"): the page posts
/// `{id, method, path, body}` to `window.webkit.messageHandlers.kindle`, the
/// model answers as serve.ts would, and the reply goes back through
/// `window.__kindleReply(id, status, json)`. State changes are pushed with
/// `window.__kindleState(json)` — what `/api/events` streams in a browser.
@MainActor
public final class Bridge {
  public static let handlerName = "kindle"

  public let model: AppModel
  public private(set) weak var webView: WKWebView?
  private var proxy: BridgeMessageProxy?

  public init(model: AppModel) {
    self.model = model
  }

  /// Register the message handler on `configuration` (before the web view is
  /// made from it) and remember the web view replies go to.
  public func install(on configuration: WKWebViewConfiguration) {
    let proxy = BridgeMessageProxy(self)
    self.proxy = proxy
    configuration.userContentController.add(proxy, contentWorld: .page, name: Self.handlerName)
  }

  public func attach(_ webView: WKWebView) {
    self.webView = webView
  }

  /// Push the current state to the page (hooked to `model.onStateChange`).
  public func pushState(_ json: String) {
    evaluate("window.__kindleState && window.__kindleState(\(Self.jsLiteral(json: json)))")
  }

  fileprivate func receive(_ message: WKScriptMessage) {
    // Only the app's own page, in its main frame, may drive the app — never
    // a frame some content managed to embed.
    guard let webView, message.webView === webView, message.frameInfo.isMainFrame,
      let request = Self.parse(message.body)
    else { return }

    Task { @MainActor in
      let response = await model.handle(
        method: request.method, path: request.path, body: request.body)
      reply(id: request.id, response)
    }
  }

  func reply(id: Any?, _ response: AppResponse) {
    evaluate(
      "window.__kindleReply && window.__kindleReply(\(Self.idLiteral(id)), \(response.status), "
        + "\(Self.jsLiteral(json: response.json)))")
  }

  private func evaluate(_ script: String) {
    webView?.evaluateJavaScript(script) { _, _ in }
  }

  // MARK: - encoding (pure, tested)

  struct Request {
    var id: Any?
    var method: String
    var path: String
    var body: Any?
  }

  /// `{id, method, path, body}` from the page; `nil` for anything else.
  static func parse(_ body: Any) -> Request? {
    guard let object = body as? [String: Any],
      let method = object["method"] as? String,
      let path = object["path"] as? String, path.hasPrefix("/")
    else { return nil }
    return Request(id: object["id"], method: method, path: path, body: object["body"])
  }

  /// A JSON text as a JavaScript expression. JSON is JavaScript except for
  /// U+2028/U+2029, which older engines read as line breaks inside strings;
  /// escaping them is harmless everywhere.
  static func jsLiteral(json: String) -> String {
    json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }

  /// The request id echoed back as the page sent it: a number or a string;
  /// anything else becomes `null`.
  static func idLiteral(_ id: Any?) -> String {
    switch id {
    case let number as NSNumber where !AppConfig.isBool(number):
      let value = number.doubleValue
      return value.isFinite ? OrderedJSON.formatNumber(value) : "null"
    case let string as String:
      var out = ""
      OrderedJSON.writeString(string, into: &out)
      return jsLiteral(json: out)
    default:
      return "null"
    }
  }
}

/// `WKUserContentController` retains its handlers; this keeps it from
/// retaining the bridge (and through it the model).
private final class BridgeMessageProxy: NSObject, WKScriptMessageHandler {
  weak var bridge: Bridge?
  init(_ bridge: Bridge) { self.bridge = bridge }

  func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated { bridge?.receive(message) }
  }
}
