import Foundation
import JavaScriptCore

/// Runs the shared pure logic (`dist-core/kindle-core.js`, built from
/// `src/core`) inside JavaScriptCore, which ships with macOS — so the app gets
/// the exact rules the CLI uses, and their tests, without carrying Node.
///
/// Every call crosses as JSON: arguments are encoded, `KindleCore[name]` is
/// invoked with the parsed values, and its result is `JSON.stringify`-ed back.
/// That keeps the boundary to Codable types on the Swift side and plain data on
/// the JS side, with no JSValue bookkeeping leaking into callers.
///
/// Not thread-safe: a JSContext belongs to one thread at a time. Use one
/// instance per actor/queue (the pipeline and the app model each own one).
public final class JSCore {
  public struct ScriptError: Error, CustomStringConvertible {
    public let function: String
    public let message: String
    public var description: String { "KindleCore.\(function): \(message)" }
  }

  private let context: JSContext
  private let invoke: JSValue

  /// - Parameter scriptURL: `kindle-core.js`. `nil` looks in the app bundle's
  ///   Resources, then `KINDLE_CORE_JS`, then the repo's `dist-core/` (tests
  ///   and `swift run` from a checkout).
  public init(scriptURL: URL? = nil) throws {
    guard let url = scriptURL ?? JSCore.locateScript() else {
      throw ScriptError(
        function: "<load>",
        message: "kindle-core.js not found — run `pnpm build:core`")
    }
    let source = try String(contentsOf: url, encoding: .utf8)

    guard let context = JSContext() else {
      throw ScriptError(function: "<load>", message: "could not create a JSContext")
    }
    var loadError: String?
    context.exceptionHandler = { _, exception in
      loadError = exception?.toString() ?? "unknown JavaScript error"
    }
    context.evaluateScript(source, withSourceURL: url)
    if let loadError { throw ScriptError(function: "<load>", message: loadError) }

    // One JS-side trampoline does the JSON crossing, so a thrown JS error comes
    // back as data instead of relying on the exception handler per call.
    context.evaluateScript(
      """
      globalThis.__kindleCoreInvoke = function (name, argsJson) {
        try {
          const fn = globalThis.KindleCore && globalThis.KindleCore[name];
          if (typeof fn !== 'function') return JSON.stringify({ error: 'no such function: ' + name });
          const result = fn.apply(null, JSON.parse(argsJson));
          return JSON.stringify({ ok: result === undefined ? null : result });
        } catch (e) {
          return JSON.stringify({ error: e && e.message !== undefined ? e.message + (e.stack ? '\\n' + e.stack : '') : String(e) });
        }
      };
      """)
    guard let invoke = context.objectForKeyedSubscript("__kindleCoreInvoke"), !invoke.isUndefined
    else {
      throw ScriptError(function: "<load>", message: "trampoline missing")
    }

    self.context = context
    self.invoke = invoke
  }

  /// Call `KindleCore[name](args...)` and decode its result as `T`.
  public func call<T: Decodable>(
    _ name: String, _ args: any Encodable..., as _: T.Type = T.self
  ) throws -> T {
    let data = try callRaw(name, args)
    return try JSONDecoder().decode(T.self, from: data)
  }

  /// The same, returning the result's raw JSON (for values passed straight
  /// back into another call or written to disk unchanged, e.g. metadata).
  public func callJSON(_ name: String, _ args: any Encodable...) throws -> Data {
    try callRaw(name, args)
  }

  private func callRaw(_ name: String, _ args: [any Encodable]) throws -> Data {
    let encoder = JSONEncoder()
    let encoded = try args.map { arg -> String in
      String(decoding: try encoder.encode(AnyEncodable(arg)), as: UTF8.self)
    }
    let argsJson = "[" + encoded.joined(separator: ",") + "]"

    guard let reply = invoke.call(withArguments: [name, argsJson])?.toString(),
      let replyData = reply.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: replyData, options: [.fragmentsAllowed])
        as? [String: Any]
    else {
      throw ScriptError(function: name, message: "no reply from JavaScript")
    }

    if let error = object["error"] as? String {
      throw ScriptError(function: name, message: error)
    }
    return try JSONSerialization.data(
      withJSONObject: object["ok"] ?? NSNull(), options: [.fragmentsAllowed])
  }

  static func locateScript() -> URL? {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent("kindle-core.js"))
    }
    if let env = ProcessInfo.processInfo.environment["KINDLE_CORE_JS"] {
      candidates.append(URL(fileURLWithPath: env))
    }
    // …/macos/Sources/KindleExportKit/Core/JSCore.swift → repo root
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    candidates.append(repo.appendingPathComponent("dist-core/kindle-core.js"))
    return candidates.first { fm.fileExists(atPath: $0.path) }
  }
}

/// Raw JSON that is passed through a call unchanged — e.g. metadata read from
/// disk and handed to KindleCore without modelling every field in Swift.
public struct RawJSON: Codable {
  public let data: Data
  public init(_ data: Data) { self.data = data }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(AnyDecodable.self)
    data = try JSONSerialization.data(withJSONObject: value.value, options: [.fragmentsAllowed])
  }

  public func encode(to encoder: Encoder) throws {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    var container = encoder.singleValueContainer()
    try container.encode(AnyEncodable(JSONAny(object)))
  }
}

// MARK: - type-erasure helpers for JSON crossing

struct AnyEncodable: Encodable {
  let value: any Encodable
  init(_ value: any Encodable) { self.value = value }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Encodes an untyped Foundation JSON object (from JSONSerialization).
struct JSONAny: Encodable {
  let object: Any
  init(_ object: Any) { self.object = object }

  func encode(to encoder: Encoder) throws {
    switch object {
    case is NSNull:
      var c = encoder.singleValueContainer(); try c.encodeNil()
    case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
      var c = encoder.singleValueContainer(); try c.encode(n.boolValue)
    case let n as NSNumber:
      var c = encoder.singleValueContainer(); try c.encode(n.doubleValue)
    case let s as String:
      var c = encoder.singleValueContainer(); try c.encode(s)
    case let a as [Any]:
      var c = encoder.unkeyedContainer()
      for item in a { try c.encode(JSONAny(item)) }
    case let d as [String: Any]:
      var c = encoder.container(keyedBy: DynamicKey.self)
      for (k, v) in d { try c.encode(JSONAny(v), forKey: DynamicKey(k)) }
    default:
      var c = encoder.singleValueContainer(); try c.encodeNil()
    }
  }
}

struct AnyDecodable: Decodable {
  let value: Any
  init(from decoder: Decoder) throws {
    if let c = try? decoder.container(keyedBy: DynamicKey.self) {
      var d: [String: Any] = [:]
      for key in c.allKeys { d[key.stringValue] = try c.decode(AnyDecodable.self, forKey: key).value }
      value = d
    } else if var c = try? decoder.unkeyedContainer() {
      var a: [Any] = []
      while !c.isAtEnd { a.append(try c.decode(AnyDecodable.self).value) }
      value = a
    } else {
      let c = try decoder.singleValueContainer()
      if c.decodeNil() { value = NSNull() }
      else if let b = try? c.decode(Bool.self) { value = b }
      else if let n = try? c.decode(Double.self) { value = n }
      else { value = try c.decode(String.self) }
    }
  }
}

struct DynamicKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(_ s: String) { stringValue = s }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue _: Int) { nil }
}
