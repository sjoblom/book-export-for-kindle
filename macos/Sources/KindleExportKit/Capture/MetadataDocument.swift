import Foundation
import JavaScriptCore

/// The `metadata.json` a capture writes, held and serialized by JavaScript so
/// the file comes out exactly as Node's
/// `JSON.stringify(normalizeBookMetadata(result), null, 2)` writes it:
/// top-level keys in `bookMetadataFieldOrder`, every nested object in the key
/// order it arrived in, numbers formatted by JS, two-space indent, no trailing
/// newline.
///
/// Parts arrive as JSON text and are `JSON.parse`d here, which keeps their
/// key order — Foundation's JSON types would not. (Key order *inside* the
/// parts is only as good as the JSON text handed in.)
public final class MetadataDocument {
  /// utils.ts `bookMetadataFieldOrder`. Unknown keys sort after these, in
  /// insertion order, as `sort-keys` with that comparator leaves them.
  public static let fieldOrder = [
    "meta", "info", "nav", "captureId", "capture", "toc", "pages", "locationMap",
  ]

  static let script = """
    var __doc = {};
    var __order = \(String(decoding: try! JSONSerialization.data(withJSONObject: fieldOrder), as: UTF8.self));
    function __set(key, json) { __doc[key] = JSON.parse(json); }
    function __setMany(json) {
      var parts = JSON.parse(json);
      for (var key in parts) __doc[key] = parts[key];
    }
    function __get(key) { return __doc[key] === undefined ? null : JSON.stringify(__doc[key]); }
    function __appendPage(json) { (__doc.pages = __doc.pages || []).push(JSON.parse(json)); }
    function __render() {
      var keys = Object.keys(__doc);
      var rank = function (k) { var i = __order.indexOf(k); return i < 0 ? Infinity : i; };
      var sorted = keys.map(function (k, i) { return [k, i]; }).sort(function (a, b) {
        var d = rank(a[0]) - rank(b[0]);
        return d !== 0 && !isNaN(d) ? d : a[1] - b[1];
      });
      var out = {};
      sorted.forEach(function (p) { out[p[0]] = __doc[p[0]]; });
      return JSON.stringify(out, null, 2);
    }
    """

  private let context: JSContext
  private var lastError: String?

  public init() {
    context = JSContext()!
    context.exceptionHandler = { [weak self] _, exception in
      self?.lastError = exception?.toString() ?? "unknown JavaScript error"
    }
    context.evaluateScript(MetadataDocument.script)
  }

  public struct DocumentError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "metadata.json: \(message)" }
  }

  private func call(_ name: String, _ args: [Any]) throws -> JSValue? {
    lastError = nil
    let value = context.objectForKeyedSubscript(name)?.call(withArguments: args)
    if let lastError { throw DocumentError(message: lastError) }
    return value
  }

  /// Set a top-level key from JSON text.
  public func set(_ key: String, json: String) throws {
    _ = try call("__set", [key, json])
  }

  public func set(_ key: String, json: Data) throws {
    try set(key, json: String(decoding: json, as: UTF8.self))
  }

  /// Merge every key of a JSON object (e.g. `buildBookMetadata`'s result).
  public func merge(json: Data) throws {
    _ = try call("__setMany", [String(decoding: json, as: UTF8.self)])
  }

  /// A top-level value as JSON text, `nil` when unset.
  public func json(_ key: String) throws -> Data? {
    guard let value = try call("__get", [key]), value.isString else { return nil }
    return Data(value.toString().utf8)
  }

  public func setCaptureId(_ id: String) throws {
    try set("captureId", json: MetadataDocument.jsonString(id))
  }

  public func setCapture(_ state: CaptureState) throws {
    try set("capture", json: MetadataDocument.json(state))
  }

  public func appendPage(_ page: CapturedScreen) throws {
    _ = try call("__appendPage", [MetadataDocument.json(page)])
  }

  /// The file's text.
  public func render() throws -> String {
    guard let value = try call("__render", []), value.isString else {
      throw DocumentError(message: "could not serialize")
    }
    return value.toString()
  }

  /// Write atomically: a reader of the file (the app, a second process) never
  /// sees half of it.
  public func write(to url: URL) throws {
    try Data(render().utf8).write(to: url, options: .atomic)
  }

  // MARK: - hand-written JSON for the Swift-side parts, in TS key order

  static func jsonString(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    let text = String(decoding: data, as: UTF8.self)
    return String(text.dropFirst().dropLast())
  }

  static func json(_ page: CapturedScreen) -> String {
    "{\"index\":\(page.index),\"page\":\(page.page),\"screenshot\":\(jsonString(page.screenshot))}"
  }

  static func json(_ state: CaptureState) -> String {
    var s =
      "{\"complete\":\(state.complete),\"reason\":\(jsonString(state.reason)),"
      + "\"lastPage\":\(state.lastPage),\"totalContentPages\":\(state.totalContentPages)"
    if let recoveries = state.recoveries {
      let items = recoveries.map {
        "{\"reason\":\(jsonString($0.reason)),\"page\":\($0.page),\"screens\":\($0.screens)}"
      }
      s += ",\"recoveries\":[" + items.joined(separator: ",") + "]"
    }
    return s + "}"
  }
}
