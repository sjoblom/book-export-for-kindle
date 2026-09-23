import Foundation

// The state the page renders — the same shape src/serve.ts `uiState()` sends,
// field for field, so one page (src/serve-page.ts) serves both the Node server
// and the app. Serialized with `OrderedJSON`, which leaves out `nil` exactly as
// `JSON.stringify` leaves out `undefined`.

/// serve.ts `AmazonState`.
public enum AmazonState: String, Sendable {
  case unknown
  case signingIn = "signing-in"
  case signedIn = "signed-in"
  case signedOut = "signed-out"
}

/// What the reader session (the one web view signed in to Amazon) is doing.
/// Only one thing can use it at a time, so sign-in, the library refresh and
/// exports take turns — serve.ts `Busy`. The app reads `.export` to decide
/// whether quitting needs a confirmation.
public enum AppBusy: String, Sendable {
  case login
  case library
  case export
}

/// serve.ts `BookJobStatus`.
public enum BookJobStatus: String, Sendable {
  case queued
  case working
  case capturing
  case transcribing
  case exporting
  case done
  case warning
  case failed

  public var isFinished: Bool { self == .done || self == .warning || self == .failed }
}

/// One book asked for since launch (serve.ts `BookJobState`). A class, as the
/// TS object is shared between the queue and the job updating it.
public final class BookJob {
  public let asin: String
  public var title: String
  public var status: BookJobStatus
  public var formats: [ExportFormat]
  /// This book is being re-captured from scratch rather than resumed.
  public var forceCapture: Bool
  /// Milliseconds since 1970, as `Date.now()`.
  public var queuedAt: Double
  public var finishedAt: Double?
  public var captured: Int?
  /// The book page the capture has reached, comparable with capturedTotal.
  public var capturedPage: Int?
  public var capturedTotal: Int?
  public var transcribed: Int?
  public var transcribedTotal: Int?
  public var warnings: [String] = []
  public var outputs: [String] = []
  public var error: String?

  init(asin: String, title: String, formats: [ExportFormat], forceCapture: Bool, queuedAt: Double) {
    self.asin = asin
    self.title = title
    status = .queued
    self.formats = formats
    self.forceCapture = forceCapture
    self.queuedAt = queuedAt
  }

  var orderedJSON: OrderedJSON {
    .object([
      ("asin", .string(asin)),
      ("title", .string(title)),
      ("status", .string(status.rawValue)),
      ("formats", .strings(formats.map(\.rawValue))),
      ("forceCapture", .bool(forceCapture)),
      ("queuedAt", .number(queuedAt)),
      ("finishedAt", finishedAt.map { .number($0) }),
      ("captured", captured.map { .int($0) }),
      ("capturedPage", capturedPage.map { .int($0) }),
      ("capturedTotal", capturedTotal.map { .int($0) }),
      ("transcribed", transcribed.map { .int($0) }),
      ("transcribedTotal", transcribedTotal.map { .int($0) }),
      ("warnings", .strings(warnings)),
      ("outputs", .strings(outputs)),
      ("error", error.map { .string($0) }),
    ])
  }
}

/// serve.ts `QueueState`.
public struct QueueLogEntry: Equatable, Sendable {
  public enum Level: String, Sendable {
    case info
    case warn
  }

  public var time: Double
  public var level: Level
  public var message: String

  var orderedJSON: OrderedJSON {
    .object([
      ("time", .number(time)),
      ("level", .string(level.rawValue)),
      ("message", .string(message)),
    ])
  }
}

/// The library as last read, `fromCache` until a refresh has replaced it.
public struct LibraryState: Equatable, Sendable {
  public var books: [LibraryBook]
  /// Milliseconds since 1970.
  public var fetchedAt: Double
  public var fromCache: Bool

  var orderedJSON: OrderedJSON {
    .object([
      ("books", .array(books.map(\.orderedJSON))),
      ("fetchedAt", .number(fetchedAt)),
      ("fromCache", .bool(fromCache)),
    ])
  }
}

extension BookCompleteness {
  var orderedJSON: OrderedJSON {
    .object([
      ("complete", .bool(complete)),
      ("capturedPages", .int(capturedPages)),
      ("transcribedPages", .int(transcribedPages)),
      (
        "missingPages",
        .array(
          missingPages.map { .object([("index", .int($0.index)), ("page", .int($0.page))]) })
      ),
      ("captureStoppedEarly", .bool(captureStoppedEarly)),
      ("remedy", remedy.map { .string($0) }),
      ("summary", summary.map { .string($0) }),
      ("warnings", .strings(warnings)),
    ])
  }
}

extension BookStatus {
  var orderedJSON: OrderedJSON {
    .object([
      ("asin", .string(asin)),
      ("title", title.map { .string($0) }),
      ("authors", authors.map { .strings($0) }),
      ("completeness", completeness.orderedJSON),
      (
        "exports",
        .array(
          exports.map { file in
            .object([
              ("name", .string(file.name)),
              ("format", .string(file.format.rawValue)),
              ("size", .number(Double(file.size))),
              ("mtimeMs", .number(file.mtimeMs)),
            ])
          })
      ),
    ])
  }
}

/// A reply to one request: the HTTP status serve.ts would send and the same
/// JSON body (errors as `{error}`).
public struct AppResponse: Sendable {
  public let status: Int
  public let json: String

  init(_ status: Int, _ body: OrderedJSON) {
    self.status = status
    json = body.serialized(pretty: false)
  }

  /// The body as Foundation objects (for tests and native callers).
  public var object: Any? {
    try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
  }
}

/// serve.ts `HttpError`: a refusal with the status the page is told.
struct AppHTTPError: Error {
  let status: Int
  let message: String

  init(_ status: Int, _ message: String) {
    self.status = status
    self.message = message
  }
}

/// A message a person can read, for any error the pipeline or WebKit throws.
func describeError(_ error: Error) -> String {
  if let localized = error as? LocalizedError, let description = localized.errorDescription {
    return description
  }
  // NSError's own `description` is a debugging dump; its localized
  // description is the readable one.
  if type(of: error) is NSError.Type { return error.localizedDescription }
  // A Swift error's own description (CaptureError is CustomStringConvertible).
  return String(describing: error)
}
