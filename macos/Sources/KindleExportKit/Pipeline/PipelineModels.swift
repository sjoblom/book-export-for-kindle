import Foundation

// The pipeline's view of the on-disk formats (src/types.ts). Only what the
// Swift side reads is modelled; metadata.json in particular stays raw JSON and
// is handed to KindleCore whole, so fields added on the TypeScript side reach
// the shared logic without a Swift change.

/// One line of text as Vision recognised it, in pixels from the top-left of
/// the page image (types.ts `OcrLine`).
public struct OcrLine: Codable, Equatable, Sendable {
  public var text: String
  public var left: Double
  public var top: Double
  public var width: Double
  public var height: Double

  public init(text: String, left: Double, top: Double, width: Double, height: Double) {
    self.text = text
    self.left = left
    self.top = top
    self.width = width
    self.height = height
  }

  var orderedJSON: OrderedJSON {
    .object([
      ("text", .string(text)),
      ("left", .number(left)),
      ("top", .number(top)),
      ("width", .number(width)),
      ("height", .number(height)),
    ])
  }
}

/// One page's transcription (types.ts `ContentChunk`).
///
/// `text` is optional because `content.json` is read from disk and may hold a
/// chunk without one; `selectReusableChunks` drops those, and a chunk the
/// transcriber writes always has it.
public struct ContentChunk: Codable, Equatable, Sendable {
  public var index: Int
  public var page: Int
  public var text: String?
  public var screenshot: String
  public var lines: [OcrLine]?

  public init(index: Int, page: Int, text: String?, screenshot: String, lines: [OcrLine]? = nil) {
    self.index = index
    self.page = page
    self.text = text
    self.screenshot = screenshot
    self.lines = lines
  }

  enum CodingKeys: String, CodingKey { case index, page, text, screenshot, lines }

  /// Lenient: a malformed chunk still loads (with index/page -1, which match
  /// no captured page) so KindleCore can judge the file as the Node side
  /// would, instead of the whole file failing to parse.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    index = ContentChunk.lenientInt(c, .index)
    page = ContentChunk.lenientInt(c, .page)
    text = try? c.decodeIfPresent(String.self, forKey: .text)
    screenshot = (try? c.decodeIfPresent(String.self, forKey: .screenshot)) ?? ""
    lines = try? c.decodeIfPresent([OcrLine].self, forKey: .lines)
  }

  private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
    if let value = try? c.decode(Int.self, forKey: key) { return value }
    if let value = try? c.decode(Double.self, forKey: key), value.isFinite { return Int(value) }
    return -1
  }

  /// Key order as the Node transcriber writes it.
  var orderedJSON: OrderedJSON {
    .object([
      ("index", .int(index)),
      ("page", .int(page)),
      ("text", text.map { .string($0) }),
      ("screenshot", .string(screenshot)),
      ("lines", lines.map { .array($0.map(\.orderedJSON)) }),
    ])
  }
}

/// A book's `content.json` (types.ts `ContentStore`).
public struct ContentStore: Codable, Equatable, Sendable {
  public var captureId: String?
  public var chunks: [ContentChunk]

  public init(captureId: String?, chunks: [ContentChunk]) {
    self.captureId = captureId
    self.chunks = chunks
  }

  var orderedJSON: OrderedJSON {
    .object([
      ("captureId", captureId.map { .string($0) }),
      ("chunks", .array(chunks.map(\.orderedJSON))),
    ])
  }
}

/// A book's `metadata.json`: the raw bytes, plus the handful of fields the
/// pipeline itself looks at.
public struct BookMetadataFile: Sendable {
  public struct Page: Codable, Equatable, Sendable {
    public var index: Int
    public var page: Int
    public var screenshot: String
  }

  public struct Capture: Codable, Equatable, Sendable {
    public var complete: Bool
    public var reason: String
    public var lastPage: Int?
    public var totalContentPages: Int?
  }

  public struct TocEntry: Codable, Equatable, Sendable {
    public var label: String
    public var depth: Int?
    public var page: Int?
    public var positionId: Int?
  }

  /// The file as read; what is handed to KindleCore.
  public let raw: Data
  public let pages: [Page]
  public let captureId: String?
  public let capture: Capture?
  public let toc: [TocEntry]
  public let title: String?
  public let authorList: [String]?
  /// `capture.totalContentPages ?? nav.totalNumContentPages ?? nav.totalNumPages`,
  /// as the Node pipeline reports capture progress.
  public let totalContentPages: Int?

  private struct Shape: Decodable {
    struct Meta: Decodable {
      var title: String?
      var authorList: [String]?
    }
    struct Nav: Decodable {
      var totalNumContentPages: Int?
      var totalNumPages: Int?
    }
    var pages: [Page]?
    var captureId: String?
    var capture: Capture?
    var toc: [TocEntry]?
    var meta: Meta?
    var nav: Nav?

    enum CodingKeys: String, CodingKey { case pages, captureId, capture, toc, meta, nav }

    // Each part optional on its own: one odd field must not hide the rest.
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      pages = try? c.decodeIfPresent([Page].self, forKey: .pages)
      captureId = try? c.decodeIfPresent(String.self, forKey: .captureId)
      capture = try? c.decodeIfPresent(Capture.self, forKey: .capture)
      toc = try? c.decodeIfPresent([TocEntry].self, forKey: .toc)
      meta = try? c.decodeIfPresent(Meta.self, forKey: .meta)
      nav = try? c.decodeIfPresent(Nav.self, forKey: .nav)
    }
  }

  public init(data: Data) throws {
    let shape = try JSONDecoder().decode(Shape.self, from: data)
    raw = data
    pages = shape.pages ?? []
    captureId = shape.captureId
    capture = shape.capture
    toc = shape.toc ?? []
    title = shape.meta?.title
    authorList = shape.meta?.authorList
    let total =
      shape.capture?.totalContentPages ?? shape.nav?.totalNumContentPages
      ?? shape.nav?.totalNumPages
    totalContentPages = (total ?? 0) > 0 ? total : nil
  }

  public var rawJSON: RawJSON { RawJSON(raw) }
}

/// A captured page with no text (capture-status.ts `MissingPage`).
public struct MissingPage: Codable, Equatable, Sendable {
  public var index: Int
  public var page: Int
}

/// capture-status.ts `BookCompleteness`, as KindleCore computes it.
public struct BookCompleteness: Codable, Equatable, Sendable {
  public var complete: Bool
  public var capturedPages: Int
  public var transcribedPages: Int
  public var missingPages: [MissingPage]
  public var captureStoppedEarly: Bool
  /// `capture-again` or `transcribe-again`.
  public var remedy: String?
  public var summary: String?
  public var warnings: [String]
}

/// A page the transcriber tried to read and could not.
public struct FailedPage: Codable, Equatable, Sendable {
  public var index: Int
  public var page: Int
  public var screenshot: String
  public var error: String
}
