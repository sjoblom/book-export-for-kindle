import Foundation
import XCTest

@testable import KindleExportKit

final class PipelineVisionTests: XCTestCase {
  func testRecognisesRenderedTextWithTopLeftBoxes() async throws {
    let dir = try PipelineFixtures.tempDir("vision")
    let image = dir.appendingPathComponent("page.png")
    let drawn = try PipelineFixtures.renderPage(
      ["The quick brown fox jumps", "over the lazy dog"], to: image, fontSize: 36, top: 150)

    let lines = try await VisionOCR().recognize(imageAt: image, attempt: 0)
    XCTAssertEqual(lines.count, 2, "\(lines)")
    let text = lines.map(\.text).joined(separator: " ")
    XCTAssertTrue(text.contains("quick brown fox"), text)
    XCTAssertTrue(text.contains("lazy dog"), text)

    // Reading order, top-left origin: the first line is above the second, and
    // both sit close to where they were drawn (measured from the top).
    let first = try XCTUnwrap(lines.first)
    let second = try XCTUnwrap(lines.last)
    XCTAssertLessThan(first.top, second.top)
    XCTAssertEqual(first.top, drawn[0].minY, accuracy: 20)
    XCTAssertEqual(second.top, drawn[1].minY, accuracy: 20)
    XCTAssertEqual(first.left, drawn[0].minX, accuracy: 20)
    XCTAssertGreaterThan(first.width, 300)
    XCTAssertGreaterThan(first.height, 15)
    // Rounded to hundredths.
    for line in lines {
      XCTAssertEqual(line.top, (line.top * 100).rounded() / 100)
    }
  }

  func testUnreadableImageIsItsOwnError() async throws {
    let dir = try PipelineFixtures.tempDir("vision")
    let bogus = dir.appendingPathComponent("broken.png")
    try Data("not a png".utf8).write(to: bogus)
    do {
      _ = try await VisionOCR().recognize(imageAt: bogus, attempt: 0)
      XCTFail("expected an error")
    } catch let error as PageUnreadableError {
      XCTAssertEqual(error.path, bogus.path)
    }
  }

  func testManyConcurrentPagesFinish() async throws {
    // Flooding Vision deadlocks it; the bounded queue must get through a burst.
    let dir = try PipelineFixtures.tempDir("vision")
    let image = dir.appendingPathComponent("page.png")
    try PipelineFixtures.renderPage(["Concurrency check"], to: image)
    let ocr = VisionOCR(maxConcurrent: 2)
    let results = try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<12 {
        group.addTask { try await ocr.recognize(imageAt: image, attempt: 0).count }
      }
      var counts: [Int] = []
      for try await count in group { counts.append(count) }
      return counts
    }
    XCTAssertEqual(results.count, 12)
    XCTAssertTrue(results.allSatisfy { $0 == 1 })
  }
}
