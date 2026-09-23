import Foundation

/// What the `kindle-export` command prints, kept apart from the printing so
/// it is tested as plain values.
public enum CommandLineOutput {
  /// One line on stdout or stderr.
  public struct Line: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
      self.text = text
      self.isError = isError
    }
  }

  /// cli.ts `renderEvents`: `[ASIN]`-prefixed lines, warnings on stderr,
  /// progress throttled to one line per 10% so a 500-page book doesn't print
  /// 500 lines.
  public struct EventRenderer: Sendable {
    public let asin: String
    private var lastTranscribed = 0
    private var lastCaptureStep = -1

    public init(asin: String) { self.asin = asin }

    public mutating func lines(for event: PipelineEvent) -> [Line] {
      switch event {
      case .info(let message):
        return [Line("[\(asin)] \(message)")]
      case .warn(let message):
        return [Line("[\(asin)] \(message)", isError: true)]
      case .transcribeProgress(let done, let total):
        let step = max(1, total / 10)
        guard done == total || done - lastTranscribed >= step else { return [] }
        lastTranscribed = done
        return [Line("[\(asin)] transcribe: \(done)/\(total) pages")]
      case .captureProgress(let captured, let page, let total):
        // The Node extractor narrates capture itself; the native capture
        // only says something every 100 screens, so progress is shown here.
        // Page, not screens, is what compares with the total.
        guard let page, let total, total > 0 else { return [] }
        let step = min(10, page * 10 / total)
        guard step > lastCaptureStep else { return [] }
        lastCaptureStep = step
        return [Line("[\(asin)] capture: page \(page) of \(total) (\(captured) screens)")]
      case .stage:
        // Implied by the lines around it.
        return []
      }
    }
  }

  /// cli.ts `formatBookLine`.
  public static func bookLine(_ book: LibraryBook) -> String {
    let authors = book.authors.isEmpty ? "" : " — \(book.authors.joined(separator: ", "))"
    var progress = ""
    if let read = book.percentageRead, read > 0 {
      progress = " (\(Int(read.rounded()))% read)"
    }
    return "\(book.title)\(authors)\(progress)"
  }

  /// cli.ts `list`, the table form.
  public static func listLines(_ books: [LibraryBook]) -> [String] {
    guard !books.isEmpty else { return ["No books found in your Kindle library."] }
    return books.map { "\($0.asin)  \(bookLine($0))" }
      + ["", "\(books.count) book\(books.count == 1 ? "" : "s")"]
  }

  /// cli.ts `list --json`: the same fields in the same order, two-space
  /// indented as `JSON.stringify(books, null, 2)` writes it.
  public static func listJSON(_ books: [LibraryBook]) -> String {
    OrderedJSON.array(books.map(\.orderedJSON)).serialized(pretty: true)
  }

  public static func duration(_ seconds: TimeInterval) -> String {
    let whole = Int(seconds)
    return "\(whole / 60)m \(whole % 60)s"
  }

  // MARK: - picker

  /// Above this many books, ask for a filter before listing them
  /// (cli.ts FILTER_PROMPT_THRESHOLD).
  public static let filterPromptThreshold = 30

  /// Books whose title or authors contain `needle`, ignoring case; a blank
  /// needle keeps them all.
  public static func filter(_ books: [LibraryBook], by needle: String) -> [LibraryBook] {
    let needle = needle.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return books }
    return books.filter {
      "\($0.title) \($0.authors.joined(separator: " "))".localizedCaseInsensitiveContains(needle)
    }
  }

  /// The numbered menu the picker shows.
  public static func pickerLines(_ books: [LibraryBook]) -> [String] {
    let width = String(books.count).count
    return books.enumerated().map { offset, book in
      let number = String(offset + 1)
      let padded = String(repeating: " ", count: width - number.count) + number
      return "\(padded)) \(bookLine(book))  [\(book.asin)]"
    }
  }

  /// What the person typed at the picker, as 0-based indices in the order
  /// given without repeats: numbers and ranges separated by spaces or commas
  /// ("1 3 5-7"), or "all". Blank means nothing.
  public static func parseSelection(_ input: String, count: Int) throws -> [Int] {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.isEmpty { return [] }
    if text == "all" || text == "*" { return Array(0..<count) }

    var picked: [Int] = []
    func add(_ number: Int) throws {
      guard number >= 1, number <= count else {
        throw CommandLineOptions.UsageError("\(number) is not in the list (1–\(count))")
      }
      if !picked.contains(number - 1) { picked.append(number - 1) }
    }
    let tokens = text.split(whereSeparator: { $0 == " " || $0 == "," })
    for token in tokens {
      let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
      if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]), low <= high {
        for number in low...high { try add(number) }
      } else if bounds.count == 1, let number = Int(token) {
        try add(number)
      } else {
        throw CommandLineOptions.UsageError("not a number or range: \(token)")
      }
    }
    return picked
  }
}
