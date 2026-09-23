import Foundation

/// An export file in a book's directory (book-status.ts `BookExportFile`).
public struct BookExportFile: Codable, Equatable, Sendable {
  public var name: String
  public var format: ExportFormat
  public var size: Int64
  public var mtimeMs: Double
}

/// What's on disk for one book, read without touching the network
/// (book-status.ts `BookStatus`).
public struct BookStatus: Codable, Equatable, Sendable {
  public var asin: String
  public var title: String?
  public var authors: [String]?
  /// The same completeness check the pipeline uses, so a badge can never
  /// disagree with what an export just said.
  public var completeness: BookCompleteness
  public var exports: [BookExportFile]
}

public enum BookScanner {
  /// Every book with any pipeline output under `outDir`, sorted by ASIN
  /// (book-status.ts `scanBooks`). Uses `core` from the caller's context.
  public static func scanBooks(outDir: URL, core: PipelineCore) -> [BookStatus] {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: outDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    else { return [] }

    var statuses: [BookStatus] = []
    for entry in entries {
      let name = entry.lastPathComponent
      guard !name.hasPrefix("."),
        (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      else { continue }
      if let status = scanBook(outDir: outDir, asin: name, core: core) {
        statuses.append(status)
      }
    }
    return statuses.sorted { $0.asin.localizedCompare($1.asin) == .orderedAscending }
  }

  public static func scanBook(outDir: URL, asin: String, core: PipelineCore) -> BookStatus? {
    let store = BookStore(outDir: outDir, asin: asin)
    let metadata = store.readMetadata()
    let content = store.readContent()

    var exports: [BookExportFile] = []
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: store.bookDir, includingPropertiesForKeys: keys, options: [])) ?? []
    for file in files {
      let name = file.lastPathComponent
      let format: ExportFormat? =
        name.hasSuffix(".md") ? .md : name.hasSuffix(".pdf") ? .pdf : nil
      guard let format, let values = try? file.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true
      else { continue }
      exports.append(
        BookExportFile(
          name: name, format: format, size: Int64(values.fileSize ?? 0),
          mtimeMs: (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))
    }

    // No asin: these lines are read in the app, where the remedy is a button
    // rather than a command to type.
    guard
      let completeness = try? core.bookCompleteness(metadata: metadata, content: content)
    else { return nil }
    if completeness.capturedPages == 0, completeness.transcribedPages == 0, exports.isEmpty {
      return nil
    }

    return BookStatus(
      asin: asin,
      title: metadata?.title,
      authors: metadata?.authorList.flatMap { try? core.normalizeAuthors($0) },
      completeness: completeness,
      exports: exports.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
  }
}
