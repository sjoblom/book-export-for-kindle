import Foundation
import XCTest

@testable import KindleExportKit

final class JSCoreTests: XCTestCase {
  func testCallsCrossAsJSON() throws {
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID()).js")
    try """
    globalThis.KindleCore = {
      add: (a, b) => a + b,
      echo: (o) => o,
      boom: () => { throw new Error('nope') },
    };
    """.write(to: script, atomically: true, encoding: .utf8)
    let core = try JSCore(scriptURL: script)

    XCTAssertEqual(try core.call("add", 2, 3, as: Int.self), 5)
    XCTAssertEqual(try core.call("echo", ["a": "b"], as: [String: String].self), ["a": "b"])
    XCTAssertThrowsError(try core.call("boom", as: Int?.self)) { error in
      XCTAssertTrue(String(describing: error).contains("nope"))
    }
  }
}
