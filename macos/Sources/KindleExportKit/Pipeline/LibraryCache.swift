import Foundation

/// The last Kindle library fetched, kept on disk so the next launch can show
/// it at once and refresh in the background (src/library-cache.ts).
///
/// The file is `kindle-export-library.json` in the given directory — for the
/// Node tool, the browser profile; for the app, wherever it keeps the
/// signed-in session's data, so the list goes with the account.
public enum LibraryCache {
  public static let fileName = "kindle-export-library.json"
  static let version = 1
  /// A cache with more books than this is not one we wrote.
  static let maxBooks = 5000

  public struct Cached: Equatable, Sendable {
    public var books: [LibraryBook]
    /// Milliseconds since 1970, as the Node side stores `Date.now()`.
    public var fetchedAt: Double

    public init(books: [LibraryBook], fetchedAt: Double) {
      self.books = books
      self.fetchedAt = fetchedAt
    }

    public init(books: [LibraryBook], fetchedAt date: Date = Date()) {
      self.init(books: books, fetchedAt: (date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    public var fetchedDate: Date { Date(timeIntervalSince1970: fetchedAt / 1000) }
  }

  public static func path(in directory: URL) -> URL {
    directory.appendingPathComponent(fileName)
  }

  /// The cached library, or `nil` when there is none or it can't be trusted.
  /// Every entry is re-validated: the page renders these titles and cover
  /// URLs, and the file is only as trustworthy as whatever last wrote it.
  public static func read(from directory: URL) -> Cached? {
    guard let data = try? Data(contentsOf: path(in: directory)),
      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = raw["version"] as? NSNumber, !isBool(version),
      version.doubleValue == Double(LibraryCache.version),
      let fetchedAt = raw["fetchedAt"] as? NSNumber, !isBool(fetchedAt),
      let entries = raw["books"] as? [Any], entries.count <= maxBooks
    else { return nil }

    var books: [LibraryBook] = []
    for entry in entries {
      guard let book = entry as? [String: Any],
        let asin = book["asin"] as? String,
        asin.range(of: #"^[A-Z0-9]{1,20}$"#, options: .regularExpression) != nil
      else { continue }

      let percentage = book["percentageRead"] as? NSNumber
      books.append(
        LibraryBook(
          asin: asin,
          title: book["title"] as? String ?? asin,
          authors: (book["authors"] as? [Any])?.compactMap { $0 as? String } ?? [],
          resourceType: book["resourceType"] as? String,
          percentageRead: percentage.flatMap { isBool($0) ? nil : $0.doubleValue },
          coverUrl: safeCoverUrl(book["coverUrl"])))
    }

    return Cached(books: books, fetchedAt: fetchedAt.doubleValue)
  }

  /// Store the library for the next launch: `{"version":1,"books":…,"fetchedAt":…}`
  /// written aside and renamed into place, readable only by the user. Failing
  /// only costs the next launch its head start, so errors are swallowed.
  public static func write(_ library: Cached, to directory: URL) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let json = OrderedJSON.object([
        ("version", .int(version)),
        ("books", .array(library.books.map(\.orderedJSON))),
        ("fetchedAt", .number(library.fetchedAt)),
      ])
      try writeFileAtomically(
        json.data(pretty: false), to: path(in: directory),
        tempName: "\(fileName).\(getpid()).tmp", permissions: 0o600)
    } catch {
      // The cache is an optimisation.
    }
  }

  /// Hosts Amazon serves product images from.
  static let coverHosts = ["media-amazon.com", "images-amazon.com", "ssl-images-amazon.com"]

  /// kindle-library.ts `safeCoverUrl`: the URL if it is https, carries no
  /// credentials and is on one of Amazon's image hosts; otherwise `nil`.
  public static func safeCoverUrl(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, var components = URLComponents(string: raw),
      components.scheme?.lowercased() == "https",
      components.user == nil, components.password == nil,
      let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }

    let onAmazon = coverHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    guard onAmazon else { return nil }

    // Normalised roughly as WHATWG `URL#toString` does for these URLs.
    components.scheme = "https"
    components.host = host
    if components.path.isEmpty { components.path = "/" }
    return components.string
  }

  private static func isBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }
}
