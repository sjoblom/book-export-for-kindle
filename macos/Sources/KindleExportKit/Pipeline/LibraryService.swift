import Foundation

/// One book in the signed-in account's Kindle library (kindle-library.ts).
public struct LibraryBook: Codable, Equatable, Sendable {
  public var asin: String
  public var title: String
  public var authors: [String]
  /// `EBOOK`, `KINDLE_EDITION_WITH_AUDIO`, … — samples and audiobooks differ.
  public var resourceType: String?
  /// 0–100, when Amazon reports reading progress.
  public var percentageRead: Double?
  /// An https URL on Amazon's image hosts; see `LibraryCache.safeCoverUrl`.
  public var coverUrl: String?

  public init(
    asin: String, title: String, authors: [String], resourceType: String? = nil,
    percentageRead: Double? = nil, coverUrl: String? = nil
  ) {
    self.asin = asin
    self.title = title
    self.authors = authors
    self.resourceType = resourceType
    self.percentageRead = percentageRead
    self.coverUrl = coverUrl
  }

  var orderedJSON: OrderedJSON {
    .object([
      ("asin", .string(asin)),
      ("title", .string(title)),
      ("authors", .strings(authors)),
      ("resourceType", resourceType.map { .string($0) }),
      ("percentageRead", percentageRead.map { .number($0) }),
      ("coverUrl", coverUrl.map { .string($0) }),
    ])
  }
}

/// Reading the signed-in account's Kindle library (kindle-library.ts
/// `fetchLibrary`).
///
/// The library page loads its contents from an internal JSON endpoint, so the
/// fetch runs inside a web view that is already on read.amazon.com, with its
/// cookies. This type only needs a way to run JavaScript there — it knows
/// nothing about the web view itself.
public actor LibraryService {
  /// Runs `script` in a page on https://read.amazon.com and returns its value.
  /// The script is the *body of an async function* ending in `return …`, as
  /// `WKWebView.callAsyncJavaScript` takes it; it returns a JSON string.
  public typealias Evaluate = (_ script: String) async throws -> Any?

  public static let searchPath = "/kindle-library/search"
  public static let defaultPageSize = 50
  /// Guard against an unbounded loop if the endpoint keeps returning a token.
  public static let maxPages = 40

  public enum LibraryError: LocalizedError, Equatable {
    case notSignedIn
    case requestFailed(String)
    case unexpectedReply

    public var errorDescription: String? {
      switch self {
      case .notSignedIn: return "Not signed in to Amazon — sign in and try again."
      case .requestFailed(let status): return "Kindle library request failed: \(status)"
      case .unexpectedReply: return "Kindle library request returned something unexpected"
      }
    }
  }

  private let core: PipelineCore

  /// - Parameter core: used only from this actor.
  public init(core: PipelineCore) { self.core = core }

  public init() throws { core = try PipelineCore() }

  /// Every book in the library, newest first, deduplicated by ASIN.
  public func fetchLibrary(
    evaluate: Evaluate, pageSize: Int = LibraryService.defaultPageSize, limit: Int? = nil,
    onProgress: ((Int) -> Void)? = nil
  ) async throws -> [LibraryBook] {
    var books: [LibraryBook] = []
    var seen = Set<String>()
    var token: String?

    for _ in 0..<LibraryService.maxPages {
      let reply = try await evaluate(LibraryService.script(pageSize: pageSize, token: token))
      let payload = try LibraryService.decodeReply(reply)

      if let object = payload as? [String: Any] {
        if object["__notSignedIn"] as? Bool == true { throw LibraryError.notSignedIn }
        if let error = object["__error"] as? String {
          if error.hasPrefix("401") || error.hasPrefix("403") { throw LibraryError.notSignedIn }
          throw LibraryError.requestFailed(error)
        }
      }

      let data = try JSONSerialization.data(
        withJSONObject: payload ?? NSNull(), options: [.fragmentsAllowed])
      let parsed = try core.parseLibraryPage(RawJSON(data))
      for book in parsed.books where !seen.contains(book.asin) {
        // The endpoint can repeat entries across pages; keep the first.
        seen.insert(book.asin)
        books.append(book)
      }

      onProgress?(books.count)

      if let limit, limit > 0, books.count >= limit { return Array(books.prefix(limit)) }
      guard let next = parsed.paginationToken, !parsed.books.isEmpty else { break }
      token = next
    }

    return books
  }

  /// The reply as a Foundation JSON value: the script returns a JSON string,
  /// but an already-bridged object is accepted too.
  static func decodeReply(_ reply: Any?) throws -> Any? {
    guard let reply, !(reply is NSNull) else { return nil }
    if let string = reply as? String {
      guard let data = string.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      else { throw LibraryError.unexpectedReply }
      return value
    }
    return reply
  }

  /// One page of the library, fetched from inside read.amazon.com exactly as
  /// the Node tool's `page.evaluate` does it.
  public static func script(pageSize: Int, token: String?) -> String {
    let tokenLiteral: String
    if let token {
      var quoted = ""
      OrderedJSON.writeString(token, into: &quoted)
      tokenLiteral = quoted
    } else {
      tokenLiteral = "null"
    }
    return """
      if (/\\/ap\\/signin|\\/gp\\/signin/.test(location.pathname)) {
        return JSON.stringify({ __notSignedIn: true });
      }
      const url = new URL(\(quoted(searchPath)), location.origin);
      url.searchParams.set('query', '');
      url.searchParams.set('libraryType', 'BOOKS');
      url.searchParams.set('sortType', 'recency');
      url.searchParams.set('querySize', String(\(pageSize)));
      const token = \(tokenLiteral);
      if (token) url.searchParams.set('paginationToken', token);
      const res = await fetch(url.toString(), {
        credentials: 'include',
        headers: { accept: 'application/json' }
      });
      if (!res.ok) return JSON.stringify({ __error: `${res.status} ${res.statusText}` });
      return JSON.stringify(await res.json());
      """
  }

  private static func quoted(_ string: String) -> String {
    var out = ""
    OrderedJSON.writeString(string, into: &out)
    return out
  }
}
