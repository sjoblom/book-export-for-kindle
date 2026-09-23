import Foundation

/// One book's directory, `<outDir>/<ASIN>`, and the files the pipeline keeps
/// in it — the same layout and formats the Node tool reads and writes
/// (content-store.ts, cleanup.ts, utils.ts).
public struct BookStore: Sendable {
  public static let contentFile = "content.json"
  public static let metadataFile = "metadata.json"
  /// utils.ts `PAGE_IMAGES_DIR`.
  public static let pageImagesDir = "pages"
  public static let renderDataDir = "data"

  public let outDir: URL
  public let asin: String

  public init(outDir: URL, asin: String) {
    self.outDir = outDir
    self.asin = asin
  }

  public var bookDir: URL { outDir.appendingPathComponent(asin, isDirectory: true) }
  public var metadataURL: URL { bookDir.appendingPathComponent(BookStore.metadataFile) }
  public var contentURL: URL { bookDir.appendingPathComponent(BookStore.contentFile) }
  public var pagesDir: URL { bookDir.appendingPathComponent(BookStore.pageImagesDir, isDirectory: true) }
  public var renderDataDir: URL { bookDir.appendingPathComponent(BookStore.renderDataDir, isDirectory: true) }
  public var pdfURL: URL { bookDir.appendingPathComponent("book.pdf") }

  public func ensureBookDir() throws {
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
  }

  // MARK: metadata.json

  /// The book's metadata, or `nil` when there is none or it doesn't parse
  /// (`tryReadJsonFile`).
  public func readMetadata() -> BookMetadataFile? {
    guard let data = try? Data(contentsOf: metadataURL) else { return nil }
    return try? BookMetadataFile(data: data)
  }

  /// The metadata as raw JSON, or `nil`.
  public func readMetadataData() -> Data? {
    try? Data(contentsOf: metadataURL)
  }

  /// Replace metadata.json with `data` exactly as given — typically JSON that
  /// KindleCore produced, whose key order (normalizeBookMetadata's) is kept by
  /// not re-encoding it here. Atomic, like content.json.
  public func writeMetadata(_ data: Data) throws {
    try ensureBookDir()
    try writeFileAtomically(
      data, to: metadataURL, tempName: ".\(BookStore.metadataFile).\(getpid()).\(nextTempId()).tmp")
  }

  // MARK: content.json

  /// content-store.ts `readContentStore`: `{captureId, chunks}`, or a bare
  /// array from before captures had an identity; `nil` if absent or not
  /// either shape.
  public func readContent() -> ContentStore? {
    guard let data = try? Data(contentsOf: contentURL) else { return nil }
    return BookStore.parseContent(data)
  }

  static func parseContent(_ data: Data) -> ContentStore? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }

    if object is [Any] {
      guard let chunks = try? JSONDecoder().decode([ContentChunk].self, from: data) else { return nil }
      return ContentStore(captureId: nil, chunks: chunks)
    }
    guard let dict = object as? [String: Any], dict["chunks"] is [Any] else { return nil }
    struct Shape: Decodable {
      var captureId: String?
      var chunks: [ContentChunk]
    }
    guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else { return nil }
    let captureId = dict["captureId"] as? String
    return ContentStore(captureId: captureId, chunks: shape.chunks)
  }

  /// content-store.ts `writeContentStore`: `JSON.stringify(store, null, 2)`
  /// written to `.content.json.<pid>.<n>.tmp` in the book directory and renamed
  /// over `content.json`, so an interrupted save leaves the previous one.
  public func writeContent(_ store: ContentStore) throws {
    try ensureBookDir()
    try writeFileAtomically(
      store.orderedJSON.data(pretty: true), to: contentURL,
      tempName: ".\(BookStore.contentFile).\(getpid()).\(nextTempId()).tmp")
  }

  /// Drop the transcription because the pages it describes are gone.
  public func invalidateContent() throws {
    // `rm --force`: already gone is fine.
    if unlink(contentURL.path) != 0, errno != ENOENT {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  // MARK: cleanup (cleanup.ts)

  /// Remove the render payloads Amazon served while capturing.
  @discardableResult
  public func cleanRenderData() throws -> CleanupResult {
    try BookStore.removeDirectory(renderDataDir)
  }

  /// Remove the captured page images. Only once every page has text.
  @discardableResult
  public func cleanPageImages() throws -> CleanupResult {
    try BookStore.removeDirectory(pagesDir)
  }

  static func directorySize(_ dir: URL) -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true
      else { continue }
      total += Int64(values.fileSize ?? 0)
    }
    return total
  }

  /// Like cleanup.ts: an empty or absent directory is left alone and reports
  /// nothing freed.
  static func removeDirectory(_ dir: URL) throws -> CleanupResult {
    let size = directorySize(dir)
    guard size > 0 else { return CleanupResult(freed: 0, removed: []) }
    try FileManager.default.removeItem(at: dir)
    return CleanupResult(freed: size, removed: [dir.path])
  }

  // MARK: page images

  /// utils.ts `resolveScreenshotPath`: `pages/…` is relative to the book
  /// directory; an absolute path is used as is; anything else is an older
  /// capture's path relative to the working directory it ran in.
  public func resolveScreenshotPath(_ screenshot: String) -> URL {
    BookStore.resolveScreenshotPath(bookDir: bookDir, screenshot)
  }

  public static func resolveScreenshotPath(bookDir: URL, _ screenshot: String) -> URL {
    if screenshot.hasPrefix("/") { return URL(fileURLWithPath: screenshot) }
    let first = screenshot.split(
      omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }
    ).first.map(String.init)
    if first == pageImagesDir { return bookDir.appendingPathComponent(screenshot) }
    return URL(fileURLWithPath: screenshot)
  }
}

/// cleanup.ts `CleanupResult`.
public struct CleanupResult: Equatable, Sendable {
  /// Bytes freed.
  public var freed: Int64
  public var removed: [String]
}

/// cleanup.ts `formatBytes`: `512 B`, `1.5 KB`, `12 MB`.
public func formatBytes(_ bytes: Int64) -> String {
  if bytes < 1024 { return "\(bytes) B" }
  let units = ["KB", "MB", "GB", "TB"]
  var value = Double(bytes) / 1024
  var unit = 0
  while value >= 1024, unit < units.count - 1 {
    value /= 1024
    unit += 1
  }
  // JS Math.round rounds halves up; toFixed(1) as String(format:).
  let number = value >= 10 ? String(Int((value + 0.5).rounded(.down))) : String(format: "%.1f", value)
  return "\(number) \(units[unit])"
}

private let tempIdLock = NSLock()
private var tempIdCounter = 0

/// content-store.ts `tempFileCounter`: unique temp names within this process.
func nextTempId() -> Int {
  tempIdLock.lock()
  defer { tempIdLock.unlock() }
  let id = tempIdCounter
  tempIdCounter += 1
  return id
}
