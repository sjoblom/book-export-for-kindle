import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import KindleExportKit

/// Shared helpers for the pipeline tests: temp directories, KindleCore when
/// the bundle is built, and page images rendered with CoreText.
enum PipelineFixtures {
  static func tempDir(_ name: String = "pipeline") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("kindle-export-tests", isDirectory: true)
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// KindleCore from dist-core/kindle-core.js, or a skip when it isn't built.
  static func core() throws -> PipelineCore {
    guard JSCore.locateScript() != nil else {
      throw XCTSkip("dist-core/kindle-core.js not built — run `pnpm build:core`")
    }
    return try PipelineCore()
  }

  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// A white page with black lines of text, the way a Kindle page screenshot
  /// looks to Vision. Returns where each line was drawn, top-left origin.
  @discardableResult
  static func renderPage(
    _ lines: [String], to url: URL, size: CGSize = CGSize(width: 1000, height: 1300),
    fontSize: CGFloat = 30, top: CGFloat = 120, left: CGFloat = 90
  ) throws -> [CGRect] {
    let width = Int(size.width)
    let height = Int(size.height)
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "fixture", code: 1) }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))

    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    var boxes: [CGRect] = []
    var y = top
    for line in lines {
      let attributed = NSAttributedString(
        string: line,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
        ])
      let ctLine = CTLineCreateWithAttributedString(attributed)
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      let lineWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
      // CoreGraphics' origin is bottom-left; `y` counts from the top.
      context.textPosition = CGPoint(x: left, y: size.height - y - ascent)
      CTLineDraw(ctLine, context)
      boxes.append(CGRect(x: left, y: y, width: CGFloat(lineWidth), height: ascent + descent))
      y += fontSize * 1.6
    }

    guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "fixture", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "fixture", code: 3) }
    return boxes
  }

  /// A three-page book: pages/000-001.png … with metadata.json.
  static func makeBook(outDir: URL, asin: String = "B000TEST01", captureId: String = "cap-1")
    throws -> BookStore
  {
    let store = BookStore(outDir: outDir, asin: asin)
    try FileManager.default.createDirectory(at: store.pagesDir, withIntermediateDirectories: true)

    let pages: [[String]] = [
      ["CHAPTER ONE", "The quick brown fox jumps over", "the lazy dog near the river bank."],
      ["It was a bright cold day in April,", "and the clocks were striking thirteen."],
      ["Chapter Two", "Call me Ishmael. Some years ago", "never mind how long precisely."],
    ]
    let numbers = [1, 2, 3]
    var pageEntries: [[String: Any]] = []
    for (index, lines) in pages.enumerated() {
      let name = String(format: "%03d-%03d.png", index, numbers[index])
      try renderPage(lines, to: store.pagesDir.appendingPathComponent(name))
      pageEntries.append(["index": index, "page": numbers[index], "screenshot": "pages/\(name)"])
    }

    let metadata: [String: Any] = [
      "meta": [
        "ACR": "", "asin": asin, "authorList": ["Doe, Jane"], "title": "A Test Book",
        "language": "en", "publisher": "Test Press", "releaseDate": "01/02/2020",
      ],
      "info": [:] as [String: Any],
      "nav": [
        "startPosition": 0, "endPosition": 100, "startContentPosition": 0,
        "startContentPage": 1, "endContentPosition": 100, "endContentPage": 3,
        "totalNumPages": 3, "totalNumContentPages": 3,
      ],
      "captureId": captureId,
      "capture": [
        "complete": true, "reason": "end-of-book", "lastPage": 3, "totalContentPages": 3,
      ],
      "toc": [
        ["label": "Chapter One", "positionId": 0, "page": 1, "depth": 0],
        ["label": "Chapter Two", "positionId": 50, "page": 3, "depth": 0],
      ],
      "pages": pageEntries,
      "locationMap": ["locations": [] as [Any], "navigationUnit": [] as [Any]],
    ]
    try store.writeMetadata(
      JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]))
    return store
  }
}
