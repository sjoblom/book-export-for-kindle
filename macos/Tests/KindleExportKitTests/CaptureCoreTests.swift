import Foundation
import XCTest

@testable import KindleExportKit

/// The capture's Swift shapes against the real KindleCore bundle
/// (dist-core/kindle-core.js). Skipped when it hasn't been built.
final class CaptureCoreTests: XCTestCase {
  var core: JSCore!

  override func setUpWithError() throws {
    guard JSCore.locateScript() != nil else {
      throw XCTSkip("dist-core/kindle-core.js not built (pnpm build:core)")
    }
    core = try JSCore()
  }

  func testParsePageNavAndNormalize() throws {
    XCTAssertEqual(
      try core.call("parsePageNav", "Page 12 of 300 ● 4%", as: PageNav?.self),
      PageNav(page: 12, total: 300))
    XCTAssertEqual(
      try core.call("parsePageNav", "Location 40 of 5000", as: PageNav?.self),
      PageNav(location: 40, total: 5000))
    XCTAssertNil(try core.call("parsePageNav", Optional<String>.none, as: PageNav?.self))
    XCTAssertNil(try core.call("parsePageNav", "Learning reading speed", as: PageNav?.self))

    let locationMap = RawJSON(
      Data(#"{"navigationUnit":[{"startPosition":0,"page":1},{"startPosition":100,"page":2}]}"#.utf8))
    XCTAssertEqual(
      try core.call(
        "normalizePageNumber", PageNav(location: 150, total: 9), locationMap, 7, as: Int.self), 2)
    XCTAssertEqual(
      try core.call("normalizePageNumber", Optional<PageNav>.none, locationMap, 7, as: Int.self), 7)
    XCTAssertEqual(try core.call("pageForPosition", locationMap, 50, as: Int.self), 1)
  }

  func testTerminationDecisions() throws {
    XCTAssertNil(
      try core.call(
        "shouldStopBeforeCapture",
        BeforeCaptureInput(hasPageNav: true, currentPage: 3, totalContentPages: 10),
        as: CaptureStop?.self))
    XCTAssertEqual(
      try core.call(
        "shouldStopBeforeCapture",
        BeforeCaptureInput(hasPageNav: true, currentPage: 11, totalContentPages: 10),
        as: CaptureStop?.self),
      CaptureStop(complete: true, reason: "past-last-content-page"))

    XCTAssertTrue(
      try core.call("isOnLastNumberedPage", FooterPosition(value: 10, total: 10), as: Bool.self))
    XCTAssertFalse(
      try core.call("isOnLastNumberedPage", FooterPosition(value: nil, total: 10), as: Bool.self))
    XCTAssertEqual(try core.call("maxNavigationAttempts", false, as: Int.self), 5)
    XCTAssertEqual(try core.call("chevronClickTimeoutMs", true, as: Double.self), 2000)
    XCTAssertEqual(
      try core.call(
        "navigationTimeoutMs", NavigationTimeoutInput(onLastNumberedPage: false, clickFailed: true),
        as: Double.self), 1000)

    let next = try core.call(
      "shouldStopCapture",
      StopCaptureInput(observations: [.stalled, .navigated], onLastNumberedPage: false, maxAttempts: 5),
      as: CaptureAction.self)
    XCTAssertEqual(next.type, "capture-next-screen")
    let end = try core.call(
      "shouldStopCapture",
      StopCaptureInput(
        observations: [.noNextPage, .noNextPage], onLastNumberedPage: true, maxAttempts: 3),
      as: CaptureAction.self)
    XCTAssertEqual(end.type, "stop")
    XCTAssertEqual(end.reason, "end-of-book")
    XCTAssertEqual(end.complete, true)

    let recover = try core.call(
      "shouldRecover", RecoveryInput(reason: "navigation-failed", page: 4, recoveries: []),
      as: RecoveryDecision.self)
    XCTAssertEqual(recover.type, "recover")
    let giveUp = try core.call(
      "shouldRecover", RecoveryInput(reason: "end-of-book", page: 4, recoveries: []),
      as: RecoveryDecision.self)
    XCTAssertEqual(giveUp.why, "not-a-stall")

    let skip = try core.call(
      "resumeScreenDecision",
      ResumeScreenInput(
        resume: ResumeState(page: 4, skipped: 0), alreadyCaptured: true, currentPage: 4,
        capturedAny: true),
      as: ResumeScreenDecision.self)
    XCTAssertEqual(skip.type, "skip")
    let lost = try core.call(
      "resumeScreenDecision",
      ResumeScreenInput(
        resume: ResumeState(page: 4, skipped: 0), alreadyCaptured: false, currentPage: 6,
        capturedAny: true),
      as: ResumeScreenDecision.self)
    XCTAssertEqual(lost.type, "lost-place")
  }

  /// The reader going away mid-book (a sign-in redirect, an unloaded page)
  /// takes the chevron with it; that must read as a stall to recover from,
  /// never as the confirmed end of the book.
  func testALostReaderIsNeverTheEndOfTheBook() throws {
    func classify(
      signedOut: Bool = false, pageImage: Bool = true, footerReadable: Bool = true,
      nextPageUsable: Bool = false
    ) throws -> NavigationResult {
      try core.call(
        "navigationResult",
        NavigationEvidence(
          navigated: false, signedOut: signedOut, pageImage: pageImage,
          footerReadable: footerReadable, nextPageUsable: nextPageUsable),
        as: NavigationResult.self)
    }
    XCTAssertEqual(try classify(), .noNextPage)
    XCTAssertEqual(try classify(nextPageUsable: true), .stalled)
    XCTAssertEqual(try classify(pageImage: false), .readerLost)
    XCTAssertEqual(try classify(footerReadable: false), .readerLost)
    XCTAssertEqual(
      try classify(signedOut: true, pageImage: false, footerReadable: false), .signedOut)

    let lost = try core.call(
      "shouldStopCapture",
      StopCaptureInput(
        observations: Array(repeating: .readerLost, count: 5), onLastNumberedPage: false,
        maxAttempts: 5),
      as: CaptureAction.self)
    XCTAssertEqual(lost.type, "stop")
    XCTAssertEqual(lost.complete, false)
    XCTAssertEqual(lost.reason, "navigation-failed")
    XCTAssertTrue(try core.call("isStall", lost.reason, as: Bool.self))

    let signedOut = try core.call(
      "shouldStopCapture",
      StopCaptureInput(observations: [.signedOut], onLastNumberedPage: false, maxAttempts: 5),
      as: CaptureAction.self)
    XCTAssertEqual(signedOut.type, "stop")
    XCTAssertEqual(signedOut.complete, false)
    XCTAssertEqual(signedOut.reason, "navigation-failed")
  }

  /// A render TAR built in the test, through `RenderFiles(tar:)` and
  /// `buildBookMetadata`, into the metadata document the engine writes.
  func testBuildMetadataFromARenderTar() throws {
    let tar = TarBuilder.archive([
      .file(
        "metadata.json",
        Data(
          #"{"firstPositionId":0,"lastPositionId":1000,"bookTitle":"T","authors":["Doe, Jane"],"lang":"en"}"#
            .utf8)),
      .file(
        "location_map.json",
        Data(
          #"{"locations":[0,100,200],"navigationUnit":[{"startPosition":0,"label":"1"},{"startPosition":100,"label":"2"},{"startPosition":200,"label":"3"}]}"#
            .utf8)),
      .file(
        "toc.json",
        Data(#"[{"label":"Chapter 1","tocPositionId":100},{"label":"Chapter 2","tocPositionId":200}]"#.utf8)),
    ])
    let render = try XCTUnwrap(try RenderFiles(tar: tar))
    let built = try core.callJSON(
      "buildBookMetadata",
      BuildMetadataInput(asin: "B000TEST00", renders: [render], yjMetadata: nil, startReading: nil))

    let doc = MetadataDocument()
    try doc.merge(json: built)
    let nav = try JSONDecoder().decode(BookNav.self, from: XCTUnwrap(try doc.json("nav")))
    XCTAssertEqual(nav.totalNumPages, 3)
    XCTAssertEqual(nav.startContentPage, 1)
    XCTAssertEqual(nav.endPosition, 1000)
    XCTAssertGreaterThan(nav.totalNumContentPages, 0)

    let meta = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(try doc.json("meta"))) as? [String: Any])
    XCTAssertEqual(meta["title"] as? String, "T")

    let rendered = try doc.render()
    let keys = ["meta", "info", "nav", "toc", "locationMap"].map {
      rendered.range(of: "\n  \"\($0)\": ")!.lowerBound
    }
    XCTAssertEqual(keys, keys.sorted(), "top-level keys in bookMetadataFieldOrder")
  }
}
