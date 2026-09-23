import Compression
import Foundation

/// Just enough of tar to read the Kindle reader's `/renderer/render`
/// responses: ustar archives of a handful of small JSON files.
///
/// Regular files only (typeflag `0` or NUL); directories, links and pax/GNU
/// extension headers are skipped, not interpreted. A gzip-wrapped archive
/// (`1f 8b`) is inflated first: the browser already undoes a
/// `Content-Encoding: gzip`, so the reader has only ever handed us plain
/// ustar, but the Node side (`extractTar`) accepts both and so does this.
public enum Tar {
  public struct FormatError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "tar: \(message)" }
  }

  /// `[path: contents]` for every regular file in the archive.
  public static func files(in archive: Data) throws -> [String: Data] {
    let bytes = [UInt8](isGzip(archive) ? try gunzip(archive) : archive)
    var files: [String: Data] = [:]
    var offset = 0

    while offset + 512 <= bytes.count {
      let header = bytes[offset..<offset + 512]
      // Two zero blocks end the archive; one is enough to stop reading.
      if header.allSatisfy({ $0 == 0 }) { break }

      let name = string(header, at: offset + 0, length: 100)
      let size = try octal(header, at: offset + 124, length: 12)
      let typeflag = bytes[offset + 156]
      let magic = string(header, at: offset + 257, length: 5)
      let prefix = magic == "ustar" ? string(header, at: offset + 345, length: 155) : ""

      let dataStart = offset + 512
      guard size >= 0, dataStart + size <= bytes.count else {
        throw FormatError(message: "entry \(name) runs past the end of the archive")
      }

      if typeflag == UInt8(ascii: "0") || typeflag == 0 {
        let path = prefix.isEmpty ? name : prefix + "/" + name
        files[path] = Data(bytes[dataStart..<dataStart + size])
      }

      offset = dataStart + (size + 511) / 512 * 512
    }

    return files
  }

  /// The file whose last path component is `name` (the reader's TARs have no
  /// directories, but don't depend on that).
  public static func file(named name: String, in files: [String: Data]) -> Data? {
    if let exact = files[name] { return exact }
    return files.first { ($0.key as NSString).lastPathComponent == name }?.value
  }

  static func isGzip(_ data: Data) -> Bool {
    data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
  }

  private static func string(_ header: ArraySlice<UInt8>, at start: Int, length: Int) -> String {
    let field = header[start..<start + length]
    let end = field.firstIndex(of: 0) ?? field.endIndex
    return String(decoding: field[start..<end], as: UTF8.self)
  }

  private static func octal(_ header: ArraySlice<UInt8>, at start: Int, length: Int) throws -> Int {
    // Base-256 (high bit set) is how GNU tar writes huge sizes; never needed here.
    if header[start] & 0x80 != 0 {
      throw FormatError(message: "base-256 sizes are not supported")
    }
    let text = string(header, at: start, length: length)
      .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    if text.isEmpty { return 0 }
    guard let value = Int(text, radix: 8) else {
      throw FormatError(message: "bad size field \(text.debugDescription)")
    }
    return value
  }

  /// Inflate a single-member gzip stream (RFC 1952).
  ///
  /// The Compression framework's `ZLIB` algorithm is raw deflate, so the gzip
  /// header and trailer are parsed here and only the deflate body handed over.
  static func gunzip(_ data: Data) throws -> Data {
    let b = [UInt8](data)
    guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else {
      throw FormatError(message: "not a deflate gzip stream")
    }
    let flags = b[3]
    var p = 10
    if flags & 0x04 != 0 {  // FEXTRA
      guard p + 2 <= b.count else { throw FormatError(message: "truncated gzip header") }
      let extraLength = Int(b[p]) | (Int(b[p + 1]) << 8)
      p += 2 + extraLength
    }
    if flags & 0x08 != 0 {  // FNAME
      while p < b.count, b[p] != 0 { p += 1 }
      p += 1
    }
    if flags & 0x10 != 0 {  // FCOMMENT
      while p < b.count, b[p] != 0 { p += 1 }
      p += 1
    }
    if flags & 0x02 != 0 { p += 2 }  // FHCRC
    guard p < b.count - 8 else { throw FormatError(message: "truncated gzip stream") }

    // ISIZE: the uncompressed length mod 2^32 — exact for anything we'd see.
    let n = b.count
    let isize =
      Int(b[n - 4]) | (Int(b[n - 3]) << 8) | (Int(b[n - 2]) << 16) | (Int(b[n - 1]) << 24)
    let capacity = max(isize, 1)
    var output = [UInt8](repeating: 0, count: capacity)
    let body = Array(b[p..<(n - 8)])
    let written = body.withUnsafeBufferPointer { src in
      output.withUnsafeMutableBufferPointer { dst in
        compression_decode_buffer(
          dst.baseAddress!, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == isize else {
      throw FormatError(message: "gzip inflated to \(written) bytes, expected \(isize)")
    }
    return Data(output[0..<written])
  }
}
