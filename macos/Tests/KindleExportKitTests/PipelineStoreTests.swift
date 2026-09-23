import Foundation
import XCTest

@testable import KindleExportKit

final class PipelineStoreTests: XCTestCase {
  func testContentRoundTripWritesWhatNodeWrites() throws {
    let store = BookStore(outDir: try PipelineFixtures.tempDir(), asin: "B0ROUND")
    let content = ContentStore(
      captureId: "cap-1",
      chunks: [
        ContentChunk(
          index: 0, page: 1, text: "Hello \"world\"\nnext\tline", screenshot: "pages/000-001.png",
          lines: [OcrLine(text: "Hello", left: 416, top: 100.5, width: 194.25, height: 28)]),
        ContentChunk(index: 1, page: 2, text: "", screenshot: "pages/001-002.png"),
      ])
    try store.writeContent(content)

    // Byte for byte what JSON.stringify(store, null, 2) produces.
    let expected = """
      {
        "captureId": "cap-1",
        "chunks": [
          {
            "index": 0,
            "page": 1,
            "text": "Hello \\"world\\"\\nnext\\tline",
            "screenshot": "pages/000-001.png",
            "lines": [
              {
                "text": "Hello",
                "left": 416,
                "top": 100.5,
                "width": 194.25,
                "height": 28
              }
            ]
          },
          {
            "index": 1,
            "page": 2,
            "text": "",
            "screenshot": "pages/001-002.png"
          }
        ]
      }
      """
    XCTAssertEqual(try String(contentsOf: store.contentURL, encoding: .utf8), expected)
    XCTAssertEqual(store.readContent(), content)
  }

  func testReadsLegacyBareArrayAndRejectsOtherShapes() throws {
    let store = BookStore(outDir: try PipelineFixtures.tempDir(), asin: "B0LEGACY")
    try store.ensureBookDir()

    try #"[{"index":0,"page":1,"text":"old","screenshot":"pages/000-001.png"}]"#
      .write(to: store.contentURL, atomically: true, encoding: .utf8)
    let legacy = try XCTUnwrap(store.readContent())
    XCTAssertNil(legacy.captureId)
    XCTAssertEqual(legacy.chunks.map(\.text), ["old"])

    try #"{"captureId":"x","chunks":"nope"}"#.write(
      to: store.contentURL, atomically: true, encoding: .utf8)
    XCTAssertNil(store.readContent())

    try "not json".write(to: store.contentURL, atomically: true, encoding: .utf8)
    XCTAssertNil(store.readContent())

    try store.invalidateContent()
    XCTAssertNil(store.readContent())
    try store.invalidateContent()  // already gone is fine
  }

  func testAtomicWriteLeavesNoTempFiles() throws {
    let store = BookStore(outDir: try PipelineFixtures.tempDir(), asin: "B0ATOMIC")
    for i in 0..<5 {
      try store.writeContent(
        ContentStore(
          captureId: nil,
          chunks: [ContentChunk(index: i, page: i + 1, text: "p\(i)", screenshot: "pages/x.png")]))
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: store.bookDir.path)
    XCTAssertEqual(names, ["content.json"])
    XCTAssertEqual(store.readContent()?.chunks.first?.text, "p4")
    // No captureId key at all when there is none, as JSON.stringify omits undefined.
    XCTAssertFalse(try String(contentsOf: store.contentURL, encoding: .utf8).contains("captureId"))
  }

  func testWriterCoalescesAndFlushes() async throws {
    let store = BookStore(outDir: try PipelineFixtures.tempDir(), asin: "B0WRITER")
    let writer = ContentWriter(store: store, captureId: "c", debounceNanoseconds: 200_000_000)

    // 20 quick completions: one forced save at 16, the rest wait for the debounce.
    for i in 0..<20 {
      await writer.add(ContentChunk(index: i, page: i, text: "\(i)", screenshot: "s"))
    }
    var writes = await writer.writes
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(store.readContent()?.chunks.count, 16)

    try await Task.sleep(nanoseconds: 500_000_000)
    writes = await writer.writes
    XCTAssertEqual(writes, 2, "the debounce saves the remaining four")
    XCTAssertEqual(store.readContent()?.chunks.count, 20)

    // Nothing new: flush has nothing to write.
    try await writer.flush()
    writes = await writer.writes
    XCTAssertEqual(writes, 2)

    // A flush saves at once, without waiting for the debounce.
    await writer.add(ContentChunk(index: 99, page: 99, text: "late", screenshot: "s"))
    try await writer.flush()
    writes = await writer.writes
    XCTAssertEqual(writes, 3)
    XCTAssertEqual(store.readContent()?.chunks.last?.index, 99)
    XCTAssertEqual(store.readContent()?.captureId, "c")

    // The first flush of a fresh writer always writes, even with nothing new.
    let fresh = ContentWriter(store: store, captureId: "c", chunks: [])
    try await fresh.flush()
    XCTAssertEqual(store.readContent()?.chunks.count, 0)
  }

  func testCleanupReportsBytesFreed() throws {
    let store = BookStore(outDir: try PipelineFixtures.tempDir(), asin: "B0CLEAN")
    try FileManager.default.createDirectory(
      at: store.pagesDir.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try Data(count: 1000).write(to: store.pagesDir.appendingPathComponent("000-001.png"))
    try Data(count: 234).write(to: store.pagesDir.appendingPathComponent("nested/x.bin"))

    let result = try store.cleanPageImages()
    XCTAssertEqual(result.freed, 1234)
    XCTAssertEqual(result.removed, [store.pagesDir.path])
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.pagesDir.path))

    // Absent: nothing freed, nothing removed.
    XCTAssertEqual(try store.cleanRenderData(), CleanupResult(freed: 0, removed: []))
  }

  func testFormatBytesAndScreenshotPaths() {
    XCTAssertEqual(formatBytes(512), "512 B")
    XCTAssertEqual(formatBytes(1536), "1.5 KB")
    XCTAssertEqual(formatBytes(12 * 1024 * 1024), "12 MB")
    XCTAssertEqual(formatBytes(3 * 1024 * 1024 * 1024 / 2), "1.5 GB")

    let book = URL(fileURLWithPath: "/tmp/out/B0X")
    XCTAssertEqual(
      BookStore.resolveScreenshotPath(bookDir: book, "pages/000-001.png").path,
      "/tmp/out/B0X/pages/000-001.png")
    XCTAssertEqual(BookStore.resolveScreenshotPath(bookDir: book, "/abs/p.png").path, "/abs/p.png")
    let legacy = BookStore.resolveScreenshotPath(bookDir: book, "out/B0X/pages/000-001.png")
    XCTAssertTrue(legacy.path.hasSuffix("/out/B0X/pages/000-001.png"))
    XCTAssertFalse(legacy.path.hasPrefix("/tmp/out/B0X/out"))
  }

  func testOrderedJSONNumbersAndStrings() {
    XCTAssertEqual(OrderedJSON.formatNumber(12), "12")
    XCTAssertEqual(OrderedJSON.formatNumber(-0.0), "0")
    XCTAssertEqual(OrderedJSON.formatNumber(0.1), "0.1")
    XCTAssertEqual(OrderedJSON.formatNumber(194.25), "194.25")
    XCTAssertEqual(OrderedJSON.formatNumber(.nan), "null")
    XCTAssertEqual(
      OrderedJSON.string("a\u{01}é\u{2028}/").serialized(pretty: false), "\"a\\u0001é\u{2028}/\"")
    XCTAssertEqual(OrderedJSON.object([]).serialized(pretty: true), "{}")
    XCTAssertEqual(OrderedJSON.array([]).serialized(pretty: true), "[]")
  }

  func testLibraryCacheRoundTripAndValidation() throws {
    let dir = try PipelineFixtures.tempDir("cache")
    let books = [
      LibraryBook(
        asin: "B0AAA", title: "One", authors: ["Jane Doe"], resourceType: "EBOOK",
        percentageRead: 42, coverUrl: "https://m.media-amazon.com/images/I/x.jpg"),
      LibraryBook(asin: "B0BBB", title: "Two", authors: []),
    ]
    LibraryCache.write(LibraryCache.Cached(books: books, fetchedAt: 1_700_000_000_000), to: dir)

    let file = LibraryCache.path(in: dir)
    let text = try String(contentsOf: file, encoding: .utf8)
    XCTAssertEqual(
      text,
      #"{"version":1,"books":[{"asin":"B0AAA","title":"One","authors":["Jane Doe"],"#
        + #""resourceType":"EBOOK","percentageRead":42,"#
        + #""coverUrl":"https://m.media-amazon.com/images/I/x.jpg"},"#
        + #"{"asin":"B0BBB","title":"Two","authors":[]}],"fetchedAt":1700000000000}"#)
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)

    XCTAssertEqual(LibraryCache.read(from: dir), LibraryCache.Cached(books: books, fetchedAt: 1_700_000_000_000))

    // Hand-edited entries are re-validated.
    try #"""
    {"version":1,"fetchedAt":5,"books":[
      {"asin":"bad asin","title":"x"},
      {"asin":"B0CCC","authors":["A",3],"coverUrl":"http://m.media-amazon.com/x.jpg"},
      {"asin":"B0DDD","title":"T","coverUrl":"https://evil.example.com/x.jpg"},
      {"asin":"B0EEE","title":"T","coverUrl":"https://images-na.ssl-images-amazon.com/x.jpg"}
    ]}
    """#.write(to: file, atomically: true, encoding: .utf8)
    let read = try XCTUnwrap(LibraryCache.read(from: dir))
    XCTAssertEqual(read.books.map(\.asin), ["B0CCC", "B0DDD", "B0EEE"])
    XCTAssertEqual(read.books[0].title, "B0CCC")
    XCTAssertEqual(read.books[0].authors, ["A"])
    XCTAssertNil(read.books[0].coverUrl)
    XCTAssertNil(read.books[1].coverUrl)
    XCTAssertEqual(read.books[2].coverUrl, "https://images-na.ssl-images-amazon.com/x.jpg")

    try #"{"version":2,"fetchedAt":5,"books":[]}"#.write(to: file, atomically: true, encoding: .utf8)
    XCTAssertNil(LibraryCache.read(from: dir))

    XCTAssertNil(LibraryCache.safeCoverUrl("https://user:pw@m.media-amazon.com/x.jpg"))
    XCTAssertNil(LibraryCache.safeCoverUrl("javascript:alert(1)"))
    XCTAssertEqual(
      LibraryCache.safeCoverUrl(" https://M.Media-Amazon.com "), "https://m.media-amazon.com/")
  }
}
