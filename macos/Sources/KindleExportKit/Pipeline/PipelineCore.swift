import Foundation

/// The KindleCore functions the pipeline uses, typed.
///
/// Wraps one `JSCore`, so it inherits its rule: one instance per actor or
/// serial context. The pipeline, the transcriber and the library service
/// each own their own.
public final class PipelineCore {
  public let js: JSCore

  public init(_ js: JSCore) { self.js = js }

  /// Loads `kindle-core.js` from the usual places (see `JSCore.init`).
  public convenience init() throws { try self.init(JSCore()) }

  /// shapePageText(reconstructParagraphs(lines), {tocLabelToStrip}).
  public func pageTextFromLines(_ lines: [OcrLine], tocLabel: String? = nil) throws -> String {
    if let tocLabel {
      return try js.call("pageTextFromLines", lines, tocLabel, as: String.self)
    }
    return try js.call("pageTextFromLines", lines, as: String.self)
  }

  /// The TOC label to strip from each chunk's text, in the order given.
  public func tocLabelsForChunks(
    _ metadata: BookMetadataFile, _ chunks: [(index: Int, page: Int)]
  ) throws -> [String?] {
    let refs = chunks.map { PageRef(index: $0.index, page: $0.page) }
    return try js.call("tocLabelsForChunks", metadata.rawJSON, refs, as: [String?].self)
  }

  /// The chunks of `store` that are text from `metadata`'s pages, by index.
  public func selectReusableChunks(
    _ store: ContentStore?, _ metadata: BookMetadataFile
  ) throws -> [ContentChunk] {
    try js.call("selectReusableChunks", store, metadata.rawJSON, as: [ContentChunk].self)
  }

  public func bookCompleteness(
    metadata: BookMetadataFile?, content: ContentStore?, asin: String? = nil
  ) throws -> BookCompleteness {
    try js.call(
      "bookCompleteness",
      CompletenessArgs(metadata: metadata?.rawJSON, content: content, asin: asin),
      as: BookCompleteness.self)
  }

  public struct RenderedMarkdown: Codable, Sendable {
    public var fileName: String
    public var markdown: String
  }

  public func renderMarkdown(_ metadata: BookMetadataFile, _ chunks: [ContentChunk]) throws
    -> RenderedMarkdown
  {
    try js.call("renderMarkdown", metadata.rawJSON, chunks, as: RenderedMarkdown.self)
  }

  public func pdfDocument(_ metadata: BookMetadataFile, _ chunks: [ContentChunk]) throws
    -> PdfBook
  {
    try js.call("pdfDocument", metadata.rawJSON, chunks, as: PdfBook.self)
  }

  public struct LibraryPage: Codable, Sendable {
    public var books: [LibraryBook]
    public var paginationToken: String?
  }

  public func parseLibraryPage(_ payload: RawJSON) throws -> LibraryPage {
    try js.call("parseLibraryPage", payload, as: LibraryPage.self)
  }

  public func normalizeAuthors(_ authors: [String]) throws -> [String] {
    try js.call("normalizeAuthors", authors, as: [String].self)
  }

  private struct PageRef: Codable {
    var index: Int
    var page: Int
  }

  private struct CompletenessArgs: Encodable {
    var metadata: RawJSON?
    var content: ContentStore?
    var asin: String?
  }
}

/// What `KindleCore.pdfDocument` returns: the book laid out as sections, each
/// section's text already formatted the way export-book-pdf.ts formats it.
public struct PdfBook: Codable, Equatable, Sendable {
  public struct Section: Codable, Equatable, Sendable {
    public var label: String
    public var depth: Int
    public var text: String

    public init(label: String, depth: Int, text: String) {
      self.label = label
      self.depth = depth
      self.text = text
    }
  }

  public var title: String
  public var authors: [String]
  public var sections: [Section]

  public init(title: String, authors: [String], sections: [Section]) {
    self.title = title
    self.authors = authors
    self.sections = sections
  }
}
