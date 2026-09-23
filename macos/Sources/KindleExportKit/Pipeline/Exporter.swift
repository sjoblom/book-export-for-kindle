import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
  case md
  case pdf
}

/// Writes a transcribed book out as Markdown or PDF
/// (export-book-markdown.ts, export-book-pdf.ts).
///
/// The content is shaped by KindleCore — the same sections, headings and
/// paragraph rules the CLI uses — so both sides export the same book. Not
/// thread-safe (it uses the caller's `PipelineCore`).
public struct Exporter {
  public let store: BookStore
  public let core: PipelineCore

  public init(store: BookStore, core: PipelineCore) {
    self.store = store
    self.core = core
  }

  public enum ExportError: LocalizedError {
    case noMetadata
    public var errorDescription: String? { "book metadata is missing or unreadable" }
  }

  /// Export in `format`, returning the file written.
  public func export(_ format: ExportFormat, content: [ContentChunk]) throws -> URL {
    switch format {
    case .md: return try exportMarkdown(content: content)
    case .pdf: return try exportPdf(content: content)
    }
  }

  /// `<bookDir>/<slug>.md`. `content` is filtered against the metadata on
  /// disk inside KindleCore, exactly as the Node exporter filters it.
  public func exportMarkdown(content: [ContentChunk]) throws -> URL {
    let metadata = try loadMetadata()
    let rendered = try core.renderMarkdown(metadata, content)
    // The name comes from KindleCore's slug of the title; keep it a plain
    // file name in the book directory whatever it says.
    let name = (rendered.fileName as NSString).lastPathComponent
    let target = store.bookDir.appendingPathComponent(name.isEmpty ? "book.md" : name)
    try writeFileAtomically(
      Data(rendered.markdown.utf8), to: target, tempName: ".\(name).\(getpid()).\(nextTempId()).tmp")
    return target
  }

  /// `<bookDir>/book.pdf`.
  public func exportPdf(content: [ContentChunk]) throws -> URL {
    let metadata = try loadMetadata()
    let book = try core.pdfDocument(metadata, content)
    let target = store.pdfURL
    try PdfRenderer().render(book, to: target)
    return target
  }

  private func loadMetadata() throws -> BookMetadataFile {
    guard let metadata = store.readMetadata() else { throw ExportError.noMetadata }
    return metadata
  }
}
