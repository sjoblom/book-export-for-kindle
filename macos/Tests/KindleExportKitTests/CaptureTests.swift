import AppKit
import Foundation
import JavaScriptCore
import XCTest

@testable import KindleExportKit

// MARK: - tar

/// A minimal ustar writer, for building archives to read back.
enum TarBuilder {
  enum Entry {
    case file(String, Data)
    case directory(String)
    case longFile(prefix: String, name: String, Data)
  }

  static func archive(_ entries: [Entry]) -> Data {
    var out = Data()
    for entry in entries {
      switch entry {
      case .file(let name, let data):
        out += header(name: name, prefix: "", size: data.count, type: "0") + padded(data)
      case .directory(let name):
        out += header(name: name, prefix: "", size: 0, type: "5")
      case .longFile(let prefix, let name, let data):
        out += header(name: name, prefix: prefix, size: data.count, type: "0") + padded(data)
      }
    }
    return out + Data(count: 1024)
  }

  static func padded(_ data: Data) -> Data {
    data + Data(count: (512 - data.count % 512) % 512)
  }

  static func header(name: String, prefix: String, size: Int, type: Character) -> Data {
    var h = [UInt8](repeating: 0, count: 512)
    func put(_ s: String, _ at: Int) { for (i, b) in s.utf8.enumerated() { h[at + i] = b } }
    put(name, 0)
    put("0000644", 100)
    put("0000000", 108)
    put("0000000", 116)
    put(String(format: "%011o", size), 124)
    put("00000000000", 136)
    h[156] = type.asciiValue!
    put("ustar", 257)
    h[262] = 0
    put("00", 263)
    put(prefix, 345)
    // Checksum: computed with the field as spaces.
    for i in 148..<156 { h[i] = 0x20 }
    let sum = h.reduce(0) { $0 + Int($1) }
    put(String(format: "%06o", sum), 148)
    h[154] = 0
    h[155] = 0x20
    return Data(h)
  }
}

final class CaptureTarTests: XCTestCase {
  func testReadsRegularFilesSkippingDirectories() throws {
    let toc = Data(#"[{"label":"Cover","tocPositionId":0}]"#.utf8)
    let big = Data((0..<1300).map { UInt8($0 % 251) })
    let exactBlock = Data(repeating: 7, count: 512)
    let archive = TarBuilder.archive([
      .directory("render/"),
      .file("toc.json", toc),
      .file("empty.json", Data()),
      .file("big.bin", big),
      .file("block.bin", exactBlock),
      .longFile(prefix: "some/deep/prefix", name: "location_map.json", Data("{}".utf8)),
    ])

    let files = try Tar.files(in: archive)
    XCTAssertEqual(
      Set(files.keys),
      ["toc.json", "empty.json", "big.bin", "block.bin", "some/deep/prefix/location_map.json"])
    XCTAssertEqual(files["toc.json"], toc)
    XCTAssertEqual(files["empty.json"], Data())
    XCTAssertEqual(files["big.bin"], big)
    XCTAssertEqual(files["block.bin"], exactBlock)
    XCTAssertEqual(Tar.file(named: "location_map.json", in: files), Data("{}".utf8))
  }

  func testRejectsTruncatedArchive() {
    let archive = TarBuilder.archive([.file("a.json", Data(repeating: 1, count: 2000))])
    XCTAssertThrowsError(try Tar.files(in: archive.prefix(1024)))
  }

  func testEmptyArchive() throws {
    XCTAssertEqual(try Tar.files(in: Data(count: 1024)), [:])
    XCTAssertEqual(try Tar.files(in: Data()), [:])
  }

  func testGzipWrappedArchive() throws {
    let archive = TarBuilder.archive([.file("metadata.json", Data(#"{"a":1}"#.utf8))])
    let gz = try gzip(archive)
    XCTAssertTrue(Tar.isGzip(gz))
    XCTAssertEqual(try Tar.files(in: gz)["metadata.json"], Data(#"{"a":1}"#.utf8))
  }

  func testRenderFilesFromTar() throws {
    let archive = TarBuilder.archive([
      .file("toc.json", Data("[]".utf8)),
      .file("location_map.json", Data(#"{"locations":[]}"#.utf8)),
      .file("page_data_0_5.json", Data("{}".utf8)),
    ])
    let render = try XCTUnwrap(try RenderFiles(tar: archive))
    XCTAssertEqual(render, RenderFiles(toc: "[]", locationMap: #"{"locations":[]}"#, metadata: nil))

    let unrelated = TarBuilder.archive([.file("page_data_0_5.json", Data("{}".utf8))])
    XCTAssertNil(try RenderFiles(tar: unrelated))

    // Absent files are left out of the JSON, as `undefined` in JS.
    let json = String(decoding: try JSONEncoder().encode(render), as: UTF8.self)
    XCTAssertFalse(json.contains("metadata"))
  }

  private func gzip(_ data: Data) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c", "-n"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(data)
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return result
  }
}

// MARK: - blob store

final class CaptureBlobStoreTests: XCTestCase {
  func testTakeConsumesAndAgesOthersOut() {
    let store = BlobStore(maxAgeInConsumptions: 2, maxCount: 100)
    store.insert(url: "stale", type: "image/png", data: Data([1]))
    for i in 0..<3 {
      store.insert(url: "page\(i)", type: "image/png", data: Data([UInt8(i)]))
      XCTAssertNotNil(store.take("page\(i)"))
    }
    // "stale" arrived at 0 consumptions; after 3 it is 3 > 2 old.
    XCTAssertFalse(store.contains("stale"))
    XCTAssertEqual(store.consumedCount, 3)
    XCTAssertNil(store.take("page0"), "a blob can only be taken once")
  }

  func testNeighbourSurvivesWithinAge() {
    let store = BlobStore(maxAgeInConsumptions: 8, maxCount: 64)
    store.insert(url: "next", type: "image/png", data: Data([2]))  // prefetched first
    store.insert(url: "current", type: "image/png", data: Data([1]))
    XCTAssertEqual(store.take("current")?.data, Data([1]))
    XCTAssertTrue(store.contains("next"))
    XCTAssertEqual(store.take("next")?.consumedAtArrival, 0)
  }

  func testSizeBackstopDropsOldestFirst() {
    let store = BlobStore(maxAgeInConsumptions: 8, maxCount: 3)
    for i in 0..<5 { store.insert(url: "u\(i)", type: "image/png", data: Data()) }
    XCTAssertEqual(store.urls, ["u2", "u3", "u4"])
  }

  func testReinsertKeepsOriginalPositionLikeAJSMap() {
    let store = BlobStore(maxAgeInConsumptions: 8, maxCount: 2)
    store.insert(url: "a", type: "", data: Data([1]))
    store.insert(url: "b", type: "", data: Data())
    store.insert(url: "a", type: "", data: Data([9]))
    store.insert(url: "c", type: "", data: Data())
    XCTAssertEqual(store.urls, ["b", "c"])
  }

  /// WebKit's reader renders pages well ahead of showing them: a blob that
  /// arrived while screen 1 was consumed became `src` nine consumptions later.
  func testKeepsABlobRenderedWellAheadWithTheDefaults() {
    let store = BlobStore()
    store.insert(url: "s0", type: "", data: Data())
    _ = store.take("s0")
    store.insert(url: "ahead", type: "", data: Data([7]))
    for i in 1...12 {
      store.insert(url: "s\(i)", type: "", data: Data())
      _ = store.take("s\(i)")
    }
    XCTAssertEqual(store.take("ahead")?.data, Data([7]))
    XCTAssertTrue(store.recentlyEvicted.isEmpty)
  }

  func testRemoveAll() {
    let store = BlobStore()
    store.insert(url: "a", type: "", data: Data())
    store.removeAll()
    XCTAssertEqual(store.count, 0)
    XCTAssertNil(store.take("a"))
  }
}

// MARK: - pure helpers

final class CaptureSupportTests: XCTestCase {
  func testPaddingMatchesExtractBook() {
    // `${totalNumContentPages * 2}`.length
    XCTAssertEqual(CaptureSupport.pageNumberPadding(totalContentPages: 371), 3)
    XCTAssertEqual(CaptureSupport.pageNumberPadding(totalContentPages: 49), 2)
    XCTAssertEqual(CaptureSupport.pageNumberPadding(totalContentPages: 50), 3)
    XCTAssertEqual(CaptureSupport.pageNumberPadding(totalContentPages: 5000), 5)
  }

  func testScreenshotPath() {
    XCTAssertEqual(CaptureSupport.screenshotPath(index: 0, page: 1, padding: 3), "pages/000-001.png")
    XCTAssertEqual(
      CaptureSupport.screenshotPath(index: 1234, page: 56, padding: 3), "pages/1234-056.png")
    // JS padStart on "-1".
    XCTAssertEqual(CaptureSupport.screenshotPath(index: 2, page: -1, padding: 3), "pages/002-0-1.png")
  }

  func testWindowPointFlipsYAndOffsetsByFrame() {
    let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
    XCTAssertEqual(
      CaptureSupport.windowPoint(css: CGPoint(x: 100, y: 50), webViewFrameInWindow: frame),
      CGPoint(x: 100, y: 670))
    // A web view inset in its window (e.g. under a toolbar / beside a sidebar).
    let inset = CGRect(x: 200, y: 30, width: 1000, height: 600)
    XCTAssertEqual(
      CaptureSupport.windowPoint(css: CGPoint(x: 10, y: 20), webViewFrameInWindow: inset),
      CGPoint(x: 210, y: 610))
    // Page zoom scales CSS px.
    XCTAssertEqual(
      CaptureSupport.windowPoint(
        css: CGPoint(x: 10, y: 20), webViewFrameInWindow: frame, zoom: 2),
      CGPoint(x: 20, y: 680))
  }

  func testDownscaleHalvesAndFloors() throws {
    let png = try makePNG(width: 201, height: 100)
    let scaled = try CaptureSupport.downscaledPNG(png)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(scaled as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, 100)
    XCTAssertEqual(image.height, 50)
    XCTAssertEqual(Array(scaled.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
    XCTAssertThrowsError(try CaptureSupport.downscaledPNG(Data("nope".utf8)))
  }

  func testSha256() {
    XCTAssertEqual(
      CaptureSupport.sha256Hex(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  private func makePNG(width: Int, height: Int) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let rep = NSBitmapImageRep(cgImage: image)
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }
}

// MARK: - metadata.json

final class CaptureMetadataTests: XCTestCase {
  func testTopLevelOrderAndFormat() throws {
    let doc = MetadataDocument()
    // Set in a scrambled order; nested key order must be kept as given.
    try doc.set("locationMap", json: #"{"locations":[1,2],"navigationUnit":[]}"#)
    try doc.appendPage(CapturedScreen(index: 0, page: 1, screenshot: "pages/000-001.png"))
    try doc.set("toc", json: #"[{"label":"A","positionId":0,"page":1,"depth":0}]"#)
    try doc.setCapture(
      CaptureState(
        complete: false, reason: "interrupted", lastPage: 1, totalContentPages: 2,
        recoveries: [CaptureRecovery(reason: "navigation-failed", page: 1, screens: 1)]))
    try doc.setCaptureId("id-1")
    try doc.set("nav", json: #"{"startPosition":0,"endPosition":10}"#)
    try doc.set("info", json: #"{"z":1,"a":2}"#)
    try doc.set("meta", json: #"{"title":"T","asin":"X"}"#)

    let expected = """
      {
        "meta": {
          "title": "T",
          "asin": "X"
        },
        "info": {
          "z": 1,
          "a": 2
        },
        "nav": {
          "startPosition": 0,
          "endPosition": 10
        },
        "captureId": "id-1",
        "capture": {
          "complete": false,
          "reason": "interrupted",
          "lastPage": 1,
          "totalContentPages": 2,
          "recoveries": [
            {
              "reason": "navigation-failed",
              "page": 1,
              "screens": 1
            }
          ]
        },
        "toc": [
          {
            "label": "A",
            "positionId": 0,
            "page": 1,
            "depth": 0
          }
        ],
        "pages": [
          {
            "index": 0,
            "page": 1,
            "screenshot": "pages/000-001.png"
          }
        ],
        "locationMap": {
          "locations": [
            1,
            2
          ],
          "navigationUnit": []
        }
      }
      """
    XCTAssertEqual(try doc.render(), expected)
  }

  func testCaptureWithoutRecoveriesOmitsTheKey() throws {
    let doc = MetadataDocument()
    try doc.setCapture(
      CaptureState(complete: true, reason: "end-of-book", lastPage: 3, totalContentPages: 3))
    XCTAssertFalse(try doc.render().contains("recoveries"))
  }

  func testUnknownKeysSortLastInInsertionOrder() throws {
    let doc = MetadataDocument()
    try doc.set("zeta", json: "1")
    try doc.set("pages", json: "[]")
    try doc.set("alpha", json: "2")
    try doc.set("meta", json: "{}")
    XCTAssertEqual(
      try doc.render(), "{\n  \"meta\": {},\n  \"pages\": [],\n  \"zeta\": 1,\n  \"alpha\": 2\n}")
  }

  func testMergeAndReadBack() throws {
    let doc = MetadataDocument()
    try doc.merge(json: Data(#"{"nav":{"startContentPage":3},"locationMap":{"a":1}}"#.utf8))
    XCTAssertEqual(try doc.json("locationMap"), Data(#"{"a":1}"#.utf8))
    XCTAssertNil(try doc.json("toc"))
    XCTAssertThrowsError(try doc.set("toc", json: "{not json"))
  }

  func testEscapesStringsForPagesAndCaptureId() throws {
    let doc = MetadataDocument()
    try doc.setCaptureId("a\"b\\c/d")
    try doc.appendPage(CapturedScreen(index: 0, page: 1, screenshot: "pages/é\n.png"))
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try doc.render().utf8)) as? [String: Any])
    XCTAssertEqual(parsed["captureId"] as? String, "a\"b\\c/d")
    let pages = try XCTUnwrap(parsed["pages"] as? [[String: Any]])
    XCTAssertEqual(pages.first?["screenshot"] as? String, "pages/é\n.png")
  }

  /// Byte-for-byte against a metadata.json the Node capture wrote, when the
  /// checkout has one (out/ is not committed).
  func testReproducesANodeWrittenFile() throws {
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let out = repo.appendingPathComponent("out")
    let candidates =
      (try? FileManager.default.contentsOfDirectory(atPath: out.path))?
      .map { out.appendingPathComponent($0).appendingPathComponent("metadata.json") }
      .filter { FileManager.default.fileExists(atPath: $0.path) } ?? []
    guard let file = candidates.first else {
      throw XCTSkip("no Node-written metadata.json under out/")
    }
    let original = try String(contentsOf: file, encoding: .utf8)

    // Split into top-level parts in JS (keeps nested order), feed them back
    // in reverse order, re-render.
    let context = try XCTUnwrap(JSContext())
    context.setObject(original, forKeyedSubscript: "source" as NSString)
    let parts = try XCTUnwrap(
      context.evaluateScript(
        "(() => { const o = JSON.parse(source); return Object.keys(o).reverse().map(k => [k, JSON.stringify(o[k])]); })()"
      )?.toArray() as? [[String]])

    let doc = MetadataDocument()
    for part in parts { try doc.set(part[0], json: part[1]) }
    XCTAssertEqual(try doc.render(), original)
  }
}

// MARK: - injected JavaScript

final class CaptureScriptTests: XCTestCase {
  /// Compile (not run: there is no DOM here) every script the session injects.
  func testScriptsCompile() throws {
    let context = try XCTUnwrap(JSContext())
    var error: String?
    context.exceptionHandler = { _, exception in error = exception?.toString() }

    for (name, source) in [("hooks", ReaderScripts.hooks), ("helpers", ReaderScripts.helpers)] {
      error = nil
      context.setObject(source, forKeyedSubscript: "source" as NSString)
      context.evaluateScript("new Function(source)")
      XCTAssertNil(error, "\(name): \(error ?? "")")
    }

    for body in ReaderScripts.bodies {
      error = nil
      context.setObject(body.body, forKeyedSubscript: "source" as NSString)
      context.setObject(body.arguments, forKeyedSubscript: "names" as NSString)
      context.evaluateScript(
        "new (Object.getPrototypeOf(async function () {}).constructor)(...names, source)")
      XCTAssertNil(error, "\(body.name): \(error ?? "")")
    }

    error = nil
    context.evaluateScript(MetadataDocument.script)
    XCTAssertNil(error, "metadata document: \(error ?? "")")
  }

  /// The helpers only define things, so they can run without a DOM; check
  /// the shape they install.
  func testHelpersInstallKx() throws {
    let context = try XCTUnwrap(JSContext())
    context.evaluateScript(ReaderScripts.helpers)
    let names = context.evaluateScript("Object.keys(globalThis.__kx).sort().join(',')")?.toString()
    XCTAssertEqual(names, "all,center,find,findAll,text,visible")
  }

  func testElementSpecEncoding() throws {
    let spec = ElementSpec.hasText("ion-item", "Go to Page")
    XCTAssertEqual(spec.flags, "i")
    let context = try XCTUnwrap(JSContext())
    context.setObject(spec.text!, forKeyedSubscript: "pattern" as NSString)
    XCTAssertEqual(
      context.evaluateScript("new RegExp(pattern, 'i').test('  go to page ')")?.toBool(), true)
    XCTAssertEqual(
      context.evaluateScript("new RegExp(pattern, 'i').test('Go to Location')")?.toBool(), false)

    let nested = ElementSpec("*", text: "x", within: ElementSpec("[role=radiogroup]"), deepest: true)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(nested)) as? [String: Any])
    XCTAssertEqual((json["within"] as? [[String: Any]])?.first?["selector"] as? String, "[role=radiogroup]")
    XCTAssertNil(json["visible"], "unset options stay undefined in JS")
  }

  func testDataURLDecoding() {
    XCTAssertEqual(ReaderSession.decodeDataURL("data:image/png;base64,AAEC"), Data([0, 1, 2]))
    XCTAssertEqual(
      ReaderSession.decodeDataURL("data:application/octet-stream;base64,"), Data())
    XCTAssertEqual(ReaderSession.decodeDataURL("data:text/plain,a%20b"), Data("a b".utf8))
    XCTAssertNil(ReaderSession.decodeDataURL("blob:https://x/y"))
  }

  func testJSONP() {
    let text = #"loadMetadata({"asin":"B0CWB2WCVZ","title":"Want"});"#
    XCTAssertEqual(ReaderSession.parseJSONP(text)?["title"] as? String, "Want")
    XCTAssertTrue(ReaderSession.jsonpNames(asin: "B0CWB2WCVZ", text))
    XCTAssertFalse(ReaderSession.jsonpNames(asin: "B000000000", text))
    XCTAssertNil(ReaderSession.parseJSONP("nothing here"))
  }

  func testKeyEvents() {
    let right = ReaderSession.keyEventFields(.arrowRight)
    XCTAssertEqual(right.0, 124)
    XCTAssertEqual(right.2, [.numericPad, .function])
    XCTAssertEqual(ReaderSession.keyEventFields(.arrowLeft).0, 123)
    XCTAssertEqual(ReaderSession.keyEventFields(.enter).1, "\r")
    XCTAssertEqual(ReaderSession.keyEventFields(.character("7")).0, 26)
    XCTAssertEqual(ReaderSession.keyEventFields(.character("0")).1, "0")
  }
}
