import Foundation
import PDFKit
import XCTest

@testable import KindleExportKit

/// A recogniser scripted per page image, counting attempts.
final class ScriptedRecognizer: PageRecognizer, @unchecked Sendable {
  struct Transient: LocalizedError {
    var errorDescription: String? { "transient" }
  }

  private let lock = NSLock()
  private var attempts: [String: Int] = [:]
  private let script: (_ name: String, _ attempt: Int) throws -> [OcrLine]

  init(_ script: @escaping (_ name: String, _ attempt: Int) throws -> [OcrLine]) {
    self.script = script
  }

  func recognize(imageAt url: URL, attempt: Int) async throws -> [OcrLine] {
    let name = url.lastPathComponent
    lock.withLock { attempts[name, default: 0] += 1 }
    return try script(name, attempt)
  }

  func attempts(_ name: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return attempts[name] ?? 0
  }

  var total: Int {
    lock.lock()
    defer { lock.unlock() }
    return attempts.values.reduce(0, +)
  }
}

final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [PipelineEvent] = []
  func append(_ event: PipelineEvent) {
    lock.lock()
    items.append(event)
    lock.unlock()
  }
  var events: [PipelineEvent] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

final class PipelineEndToEndTests: XCTestCase {
  func testTranscribesAFixtureBookWithVision() async throws {
    let core = try PipelineFixtures.core()
    let store = try PipelineFixtures.makeBook(outDir: try PipelineFixtures.tempDir("e2e"))

    let progress = EventLog()
    let transcriber = Transcriber(store: store, core: core, ocr: VisionOCR())
    let result = try await transcriber.transcribe(onProgress: { done, total in
      progress.append(.transcribeProgress(done: done, total: total))
    })

    XCTAssertEqual(result.failedPages, [])
    XCTAssertEqual(result.content.map(\.index), [0, 1, 2])
    XCTAssertEqual(progress.events.last, .transcribeProgress(done: 3, total: 3))

    let saved = try XCTUnwrap(store.readContent())
    XCTAssertEqual(saved.captureId, "cap-1")
    XCTAssertEqual(saved.chunks, result.content)
    XCTAssertTrue(saved.chunks.allSatisfy { !($0.lines ?? []).isEmpty })
    XCTAssertTrue(saved.chunks[0].text?.contains("quick brown fox") == true, "\(saved.chunks[0])")
    XCTAssertTrue(saved.chunks[1].text?.contains("clocks were striking") == true)
    XCTAssertEqual(saved.chunks[0].screenshot, "pages/000-001.png")

    let markdown = try Exporter(store: store, core: core).exportMarkdown(content: result.content)
    XCTAssertEqual(markdown.lastPathComponent, "a_test_book.md")
    let text = try String(contentsOf: markdown, encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("# A Test Book\n\n> By Jane Doe"), String(text.prefix(80)))
    XCTAssertTrue(text.contains("## Chapter One"))
    XCTAssertTrue(text.contains("## Chapter Two"))
    XCTAssertTrue(text.contains("lazy dog"))
  }

  func testPipelineTranscribesExportsBothFormatsAndCleansPages() async throws {
    let outDir = try PipelineFixtures.tempDir("e2e")
    let store = try PipelineFixtures.makeBook(outDir: outDir)
    _ = try PipelineFixtures.core()

    let log = EventLog()
    let pipeline = BookPipeline(outDir: outDir)
    let result = try await pipeline.process(
      asin: store.asin, options: .init(formats: [.md, .pdf]), emit: { log.append($0) })

    XCTAssertTrue(result.completeness.complete, "\(result.completeness)")
    XCTAssertFalse(result.fellShort())
    XCTAssertEqual(result.outputs.map(\.lastPathComponent), ["a_test_book.md", "book.pdf"])
    XCTAssertEqual(
      log.events.filter { if case .stage = $0 { return true } else { return false } },
      [.stage(.transcribe), .stage(.export)])
    XCTAssertTrue(log.events.contains(.info("capture: reusing 3 existing page images")))
    XCTAssertTrue(log.events.contains { if case .info(let m) = $0 { return m.hasPrefix("transcribe: freed") } else { return false } })

    // Every page has text, so the images are gone.
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.pagesDir.path))

    let pdf = try XCTUnwrap(PDFDocument(url: store.pdfURL))
    XCTAssertGreaterThanOrEqual(pdf.pageCount, 3, "title page + one page per section")
    XCTAssertEqual(pdf.outlineRoot?.numberOfChildren, 3, "Title Page + two sections")
    XCTAssertEqual(pdf.outlineRoot?.child(at: 1)?.label, "Chapter One")
    XCTAssertTrue(pdf.page(at: 0)?.string?.contains("A Test Book") == true)
    XCTAssertTrue(pdf.string?.contains("lazy dog") == true)
    XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "A Test Book")

    // Run again: everything is reused, nothing is read, lock free again.
    let again = EventLog()
    let second = try await pipeline.process(asin: store.asin, emit: { again.append($0) })
    XCTAssertTrue(again.events.contains(.info("transcribe: reusing 3 chunks")))
    XCTAssertTrue(second.completeness.complete)
    XCTAssertFalse(FileManager.default.fileExists(atPath: BookLock.lockPath(store.bookDir).path))

    // The scanner agrees with the pipeline.
    let statuses = BookScanner.scanBooks(outDir: outDir, core: try PipelineFixtures.core())
    XCTAssertEqual(statuses.map(\.asin), [store.asin])
    XCTAssertEqual(statuses.first?.title, "A Test Book")
    XCTAssertEqual(statuses.first?.authors, ["Jane Doe"])
    XCTAssertEqual(statuses.first?.exports.map(\.name), ["a_test_book.md", "book.pdf"])
    XCTAssertEqual(statuses.first?.completeness.complete, true)
  }

  func testRetryRulesBlankPagesAndFailedPages() async throws {
    let core = try PipelineFixtures.core()
    let store = try PipelineFixtures.makeBook(outDir: try PipelineFixtures.tempDir("retry"))
    // The last page's image vanishes mid-run: it must fail without retries.
    try FileManager.default.removeItem(at: store.pagesDir.appendingPathComponent("002-003.png"))

    let line = OcrLine(text: "Recovered text on the page.", left: 90, top: 120, width: 500, height: 30)
    let recognizer = ScriptedRecognizer { name, attempt in
      switch name {
      case "000-001.png":
        if attempt < 2 { throw ScriptedRecognizer.Transient() }
        return [line]
      case "001-002.png":
        return []  // always blank
      default:
        throw ScriptedRecognizer.Transient()
      }
    }

    let result = try await Transcriber(store: store, core: core, ocr: recognizer).transcribe(
      options: .init(concurrency: 3, retryDelay: { _ in 1_000_000 }))

    XCTAssertEqual(recognizer.attempts("000-001.png"), 3)
    XCTAssertEqual(recognizer.attempts("001-002.png"), 3, "blank retried up to three reads")
    XCTAssertEqual(recognizer.attempts("002-003.png"), 1, "a missing image is not retried")

    XCTAssertEqual(result.content.map(\.index), [0, 1])
    XCTAssertEqual(result.content[0].text, "Recovered text on the page.")
    XCTAssertEqual(result.content[1].text, "")
    XCTAssertNil(result.content[1].lines, "no lines key for a blank page")
    XCTAssertEqual(result.failedPages.map(\.index), [2])
    XCTAssertTrue(result.failedPages[0].error.contains("missing or unreadable"))

    // Saved incrementally and finally: the two read pages are on disk, and a
    // re-run only reads the one that failed.
    XCTAssertEqual(store.readContent()?.chunks.map(\.index), [0, 1])
    let completeness = try core.bookCompleteness(
      metadata: store.readMetadata(), content: store.readContent())
    XCTAssertEqual(completeness.missingPages, [MissingPage(index: 2, page: 3)])
    XCTAssertEqual(completeness.remedy, "transcribe-again")
  }

  func testMissingPageImagesIsAFriendlyError() async throws {
    let core = try PipelineFixtures.core()
    let store = try PipelineFixtures.makeBook(outDir: try PipelineFixtures.tempDir("gone"))
    try store.cleanPageImages()
    do {
      _ = try await Transcriber(store: store, core: core, ocr: VisionOCR()).transcribe()
      XCTFail("expected an error")
    } catch let error as Transcriber.TranscribeError {
      XCTAssertEqual(error, .pageImagesGone(asin: store.asin))
      XCTAssertTrue(error.localizedDescription.contains("Capture the book again"))
    }
  }

  func testInjectedCaptureInvalidatesOldTextAndReportsProgress() async throws {
    _ = try PipelineFixtures.core()
    let outDir = try PipelineFixtures.tempDir("capture")
    let asin = "B000TEST01"
    let store = BookStore(outDir: outDir, asin: asin)
    // Text from an earlier capture and leftover render data.
    try store.writeContent(
      ContentStore(
        captureId: "old",
        chunks: [ContentChunk(index: 0, page: 1, text: "stale", screenshot: "pages/000-001.png")]))
    try FileManager.default.createDirectory(at: store.renderDataDir, withIntermediateDirectories: true)
    try Data(count: 2048).write(to: store.renderDataDir.appendingPathComponent("render.tar"))

    let log = EventLog()
    let recognizer = ScriptedRecognizer { name, _ in
      [OcrLine(text: "Text of \(name)", left: 0, top: 0, width: 100, height: 20)]
    }
    let pipeline = BookPipeline(
      outDir: outDir,
      capture: { asin, store in
        _ = try PipelineFixtures.makeBook(outDir: store.outDir, asin: asin, captureId: "new")
      },
      recognizer: recognizer)
    let result = try await pipeline.process(
      asin: asin, options: .init(keepPages: true, forceCapture: true), emit: { log.append($0) })

    XCTAssertEqual(recognizer.total, 3, "old text was dropped, every page read")
    XCTAssertEqual(store.readContent()?.captureId, "new")
    XCTAssertTrue(log.events.contains(.stage(.capture)))
    XCTAssertTrue(log.events.contains(.info("capture: 3 page images")))
    XCTAssertTrue(log.events.contains(.info("capture: freed 2.0 KB of render data")))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.pagesDir.path), "keepPages")
    XCTAssertTrue(result.completeness.complete)
  }

  func testBusyBookIsRefused() async throws {
    let outDir = try PipelineFixtures.tempDir("busy")
    let store = try PipelineFixtures.makeBook(outDir: outDir)
    let held = try BookLock.acquire(bookDir: store.bookDir, command: "all")
    defer { held.release() }

    let pipeline = BookPipeline(
      outDir: outDir, makeCore: { try PipelineFixtures.core() },
      lockProbes: .init(isAlive: { _ in true }, commandLine: { _ in "node kindle-export" }))
    do {
      _ = try await pipeline.process(asin: store.asin)
      XCTFail("expected BookBusyError")
    } catch let error as BookBusyError {
      XCTAssertEqual(error.pid, getpid())
    }
  }

  // MARK: library

  func testLibraryPagesThroughDedupsAndLimits() async throws {
    let service = LibraryService(core: try PipelineFixtures.core())
    let pages: [String] = [
      #"{"itemsList":[{"asin":"b0one","title":"One","authors":["Doe, Jane:"],"productUrl":"https://m.media-amazon.com/images/I/1.jpg","percentageRead":12,"resourceType":"EBOOK"},{"asin":"B0TWO","title":"Two","authors":["Roe, Rick:"]}],"paginationToken":"t1"}"#,
      #"{"itemsList":[{"asin":"B0TWO","title":"Two again"},{"asin":"B0THREE","title":"Three","productUrl":"http://evil.example.com/x.jpg"}],"paginationToken":"t2"}"#,
      #"{"itemsList":[],"paginationToken":"t3"}"#,
    ]
    let scripts = ScriptLog()
    let books = try await service.fetchLibrary(evaluate: { script in
      let n = scripts.append(script)
      return pages[n]
    })

    XCTAssertEqual(books.map(\.asin), ["B0ONE", "B0TWO", "B0THREE"])
    XCTAssertEqual(books[0].authors, ["Jane Doe"])
    XCTAssertEqual(books[0].coverUrl, "https://m.media-amazon.com/images/I/1.jpg")
    XCTAssertEqual(books[0].percentageRead, 12)
    XCTAssertEqual(books[1].title, "Two")
    XCTAssertNil(books[2].coverUrl)
    XCTAssertEqual(scripts.all.count, 3, "stops on an empty page")
    XCTAssertTrue(scripts.all[0].contains("const token = null;"))
    XCTAssertTrue(scripts.all[1].contains(#"const token = "t1";"#))
    XCTAssertTrue(scripts.all[0].contains("/kindle-library/search"))

    let limited = try await service.fetchLibrary(evaluate: { _ in pages[0] }, limit: 1)
    XCTAssertEqual(limited.map(\.asin), ["B0ONE"])

    // A token forever: capped at MAX_PAGES requests.
    let endless = ScriptLog()
    _ = try await service.fetchLibrary(evaluate: { script in
      _ = endless.append(script)
      return pages[0]
    })
    XCTAssertEqual(endless.all.count, LibraryService.maxPages)
  }

  func testLibrarySignInErrors() async throws {
    let service = LibraryService(core: try PipelineFixtures.core())
    for reply in [#"{"__error":"401 Unauthorized"}"#, #"{"__error":"403 Forbidden"}"#, #"{"__notSignedIn":true}"#] {
      do {
        _ = try await service.fetchLibrary(evaluate: { _ in reply })
        XCTFail("expected notSignedIn for \(reply)")
      } catch let error as LibraryService.LibraryError {
        XCTAssertEqual(error, .notSignedIn)
      }
    }
    do {
      _ = try await service.fetchLibrary(evaluate: { _ in ["__error": "500 Server Error"] })
      XCTFail("expected a failure")
    } catch let error as LibraryService.LibraryError {
      XCTAssertEqual(error, .requestFailed("500 Server Error"))
    }
    // An unrecognised payload is an empty library, as in the Node tool.
    let none = try await service.fetchLibrary(evaluate: { _ in ["something": "else"] })
    XCTAssertEqual(none, [])
  }

  // MARK: real book

  /// The Node tool's own export of a real book (out/B0CWB2WCVZ/want.md),
  /// reproduced from its metadata.json and content.json.
  func testRealBookExportsLikeTheNodeTool() async throws {
    let core = try PipelineFixtures.core()
    let source = PipelineFixtures.repoRoot.appendingPathComponent("out/B0CWB2WCVZ")
    guard FileManager.default.fileExists(atPath: source.appendingPathComponent("content.json").path)
    else { throw XCTSkip("out/B0CWB2WCVZ not present") }

    let outDir = try PipelineFixtures.tempDir("real")
    let store = BookStore(outDir: outDir, asin: "B0CWB2WCVZ")
    try store.ensureBookDir()
    for file in ["metadata.json", "content.json"] {
      try FileManager.default.copyItem(
        at: source.appendingPathComponent(file), to: store.bookDir.appendingPathComponent(file))
    }

    let metadata = try XCTUnwrap(store.readMetadata())
    let content = try core.selectReusableChunks(store.readContent(), metadata)
    XCTAssertEqual(content.count, metadata.pages.count)

    // Content round-trips byte for byte through the Swift writer.
    try store.writeContent(XCTUnwrap(store.readContent()))
    XCTAssertEqual(
      try Data(contentsOf: store.contentURL),
      try Data(contentsOf: source.appendingPathComponent("content.json")))

    let exporter = Exporter(store: store, core: core)
    let markdown = try exporter.exportMarkdown(content: content)
    let want = try String(contentsOf: source.appendingPathComponent("want.md"), encoding: .utf8)
    let got = try String(contentsOf: markdown, encoding: .utf8)
    if got != want {
      let a = got.split(separator: "\n", omittingEmptySubsequences: false)
      let b = want.split(separator: "\n", omittingEmptySubsequences: false)
      let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }
      XCTFail(
        "markdown differs from want.md (\(a.count) vs \(b.count) lines); first at line "
          + "\((first?.offset ?? min(a.count, b.count)) + 1):\n got: \(first?.element.0 ?? "")\nwant: \(first?.element.1 ?? "")")
    }

    let started = Date()
    _ = try exporter.exportPdf(content: content)
    let pdf = try XCTUnwrap(PDFDocument(url: store.pdfURL))
    XCTAssertGreaterThan(pdf.pageCount, 100)
    XCTAssertEqual(pdf.outlineRoot?.child(at: 0)?.label, "Title Page")
    print("real book PDF: \(pdf.pageCount) pages in \(Date().timeIntervalSince(started))s")
  }
}

final class ScriptLog: @unchecked Sendable {
  private let lock = NSLock()
  private var scripts: [String] = []
  /// Appends and returns the index it was stored at.
  func append(_ script: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    scripts.append(script)
    return scripts.count - 1
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return scripts
  }
}
