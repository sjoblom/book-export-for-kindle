import Foundation

/// A JSON value with its key order kept, written exactly as JavaScript's
/// `JSON.stringify(value, null, 2)` (or without the indent) writes it.
///
/// The files the pipeline writes are shared with the Node tool, which reads
/// them back and whose tests diff them. `JSONSerialization` and `JSONEncoder`
/// neither keep key order nor format numbers the way JavaScript does (`12`
/// rather than `12.0`), so the few files written from Swift go through this.
enum OrderedJSON {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([OrderedJSON])
  /// Keys in the order they are written. A `nil` value is left out, as
  /// `JSON.stringify` leaves out `undefined`.
  case object([(String, OrderedJSON?)])

  /// `JSON.stringify(self, null, indent ? 2 : undefined)`.
  func serialized(pretty: Bool) -> String {
    var out = ""
    write(into: &out, pretty: pretty, depth: 0)
    return out
  }

  func data(pretty: Bool) -> Data { Data(serialized(pretty: pretty).utf8) }

  private func write(into out: inout String, pretty: Bool, depth: Int) {
    switch self {
    case .null:
      out += "null"
    case .bool(let value):
      out += value ? "true" : "false"
    case .number(let value):
      out += OrderedJSON.formatNumber(value)
    case .string(let value):
      OrderedJSON.writeString(value, into: &out)
    case .array(let items):
      if items.isEmpty {
        out += "[]"
        return
      }
      out += "["
      for (i, item) in items.enumerated() {
        if i > 0 { out += "," }
        if pretty { out += "\n" + OrderedJSON.indent(depth + 1) }
        item.write(into: &out, pretty: pretty, depth: depth + 1)
      }
      if pretty { out += "\n" + OrderedJSON.indent(depth) }
      out += "]"
    case .object(let pairs):
      let present = pairs.compactMap { key, value in value.map { (key, $0) } }
      if present.isEmpty {
        out += "{}"
        return
      }
      out += "{"
      for (i, (key, value)) in present.enumerated() {
        if i > 0 { out += "," }
        if pretty { out += "\n" + OrderedJSON.indent(depth + 1) }
        OrderedJSON.writeString(key, into: &out)
        out += pretty ? ": " : ":"
        value.write(into: &out, pretty: pretty, depth: depth + 1)
      }
      if pretty { out += "\n" + OrderedJSON.indent(depth) }
      out += "}"
    }
  }

  private static func indent(_ depth: Int) -> String {
    String(repeating: "  ", count: depth)
  }

  /// JavaScript's Number-to-String for the values the pipeline writes:
  /// integral values without a fraction, others in their shortest round-trip
  /// form (which Swift's `description` also produces), non-finite as `null`.
  static func formatNumber(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) < 1e21 {
      if value == 0 { return "0" }  // -0 too, as JSON.stringify writes it
      if abs(value) < 9.007_199_254_740_992e15 { return String(Int64(value)) }
    }
    return String(describing: value)
  }

  /// JSON.stringify's string quoting: `"` and `\` escaped, the short escapes
  /// for \b \f \n \r \t, other control characters as \u00XX, and everything
  /// else — including non-ASCII — written as is.
  static func writeString(_ value: String, into out: inout String) {
    out += "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
  }
}

extension OrderedJSON {
  static func int(_ value: Int) -> OrderedJSON { .number(Double(value)) }
  static func strings(_ values: [String]) -> OrderedJSON { .array(values.map { .string($0) }) }
}

/// Replace `target` with `data` in one step: written to a temp file beside it
/// and renamed over it, so a crash mid-write leaves the previous file intact.
///
/// `rename(2)` rather than `FileManager.moveItem`, which refuses to replace an
/// existing file.
func writeFileAtomically(
  _ data: Data, to target: URL, tempName: String, permissions: mode_t? = nil
) throws {
  let temp = target.deletingLastPathComponent().appendingPathComponent(tempName)
  do {
    var attributes: [FileAttributeKey: Any]? = nil
    if let permissions { attributes = [.posixPermissions: NSNumber(value: permissions)] }
    guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: attributes)
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if rename(temp.path, target.path) != 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  } catch {
    try? FileManager.default.removeItem(at: temp)
    throw error
  }
}
