import Foundation

// Swift mirrors of the values that cross into KindleCore during a capture
// (src/types.ts, src/capture-termination.ts). Decisions are made in
// JavaScript; these only carry them. Optional fields are omitted when nil, so
// JS sees `undefined` exactly where the TS types allow it.

/// What the reader's footer says (`parsePageNav`).
public struct PageNav: Codable, Equatable, Sendable {
  public var page: Int?
  public var location: Int?
  public var total: Int

  public init(page: Int? = nil, location: Int? = nil, total: Int) {
    self.page = page
    self.location = location
    self.total = total
  }
}

/// `BookMetadata.nav`.
public struct BookNav: Codable, Equatable, Sendable {
  public var startPosition: Int
  public var endPosition: Int
  public var startContentPosition: Int
  public var startContentPage: Int
  public var endContentPosition: Int
  public var endContentPage: Int
  public var totalNumPages: Int
  public var totalNumContentPages: Int
}

/// `PageChunk` (TS) — one captured screen.
public struct CapturedScreen: Codable, Equatable, Sendable {
  public var index: Int
  public var page: Int
  public var screenshot: String

  public init(index: Int, page: Int, screenshot: String) {
    self.index = index
    self.page = page
    self.screenshot = screenshot
  }
}

/// `CaptureRecovery`.
public struct CaptureRecovery: Codable, Equatable, Sendable {
  public var reason: String
  public var page: Int
  public var screens: Int
}

/// `CaptureStatus` (TS), stamped into metadata.json before the first page and
/// updated in place.
public struct CaptureState: Codable, Equatable, Sendable {
  public var complete: Bool
  public var reason: String
  public var lastPage: Int
  public var totalContentPages: Int
  public var recoveries: [CaptureRecovery]?
}

/// A `{type: 'stop', complete, reason}` action (from `shouldStopBeforeCapture`
/// or `shouldStopCapture`).
public struct CaptureStop: Codable, Equatable, Sendable {
  public var type: String = "stop"
  public var complete: Bool
  public var reason: String

  public init(complete: Bool, reason: String) {
    self.complete = complete
    self.reason = reason
  }
}

/// `CaptureAction` from `shouldStopCapture`.
public struct CaptureAction: Decodable, Sendable {
  public var type: String  // capture-next-screen | retry-navigation | stop
  public var complete: Bool?
  public var reason: String?
}

/// `RecoveryDecision` from `shouldRecover`.
public struct RecoveryDecision: Decodable, Sendable {
  public var type: String  // recover | give-up
  public var why: String?  // not-a-stall | recovery-limit | stuck-here
}

/// `ResumeState`.
public struct ResumeState: Codable, Equatable, Sendable {
  public var page: Int
  public var skipped: Int
}

/// `ResumeScreenDecision` from `resumeScreenDecision`.
public struct ResumeScreenDecision: Decodable, Sendable {
  public var type: String  // skip | capture | lost-place
  public var possibleDuplicates: Bool?
}

/// A page-turn attempt's outcome (`NavigationResult`).
public enum NavigationResult: String, Codable, Sendable {
  case navigated
  case noNextPage = "no-next-page"
  case stalled
}

/// The text files of one `/renderer/render` TAR, in the shape
/// `KindleCore.buildBookMetadata` takes (`RenderFiles`).
public struct RenderFiles: Codable, Equatable, Sendable {
  public var toc: String?
  public var locationMap: String?
  public var metadata: String?

  public init(toc: String? = nil, locationMap: String? = nil, metadata: String? = nil) {
    self.toc = toc
    self.locationMap = locationMap
    self.metadata = metadata
  }

  /// Pull the three files out of a render TAR; `nil` when it has none of them.
  public init?(tar: Data) throws {
    let files = try Tar.files(in: tar)
    func text(_ name: String) -> String? {
      Tar.file(named: name, in: files).map { String(decoding: $0, as: UTF8.self) }
    }
    toc = text("toc.json")
    locationMap = text("location_map.json")
    metadata = text("metadata.json")
    if toc == nil, locationMap == nil, metadata == nil { return nil }
  }
}
