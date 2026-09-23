import Foundation

/// The native `kindle-export` command line (macos/Sources/KindleExportCLI):
/// its arguments, help and version. Pure, so it is tested without a terminal;
/// the executable only acts on what `parse` returns.
///
/// Mirrors src/cli.ts `parseArgs` where the two tools overlap, so a command
/// written for one works with the other. What only the Node tool has (OpenAI
/// models, a Chrome profile, the web server) is refused with a pointer
/// instead of being silently ignored.
public enum CommandLineOptions {
  /// Kept equal to package.json's version: scripts/package-app.sh refuses to
  /// build when they differ, and a test checks it. The bundled tool reports
  /// the app's Info.plist version instead (`resolvedVersion`), which the same
  /// script writes from package.json.
  public static let version = "0.3.0"
  public static let programName = "kindle-export"
  /// The app's bundle identifier (scripts/package-app.sh).
  public static let appBundleIdentifier = "com.kindle-export.app"

  public enum Command: String, Equatable, Sendable, CaseIterable {
    /// Capture if needed, transcribe, export — or, with no ASINs, pick books.
    case all
    case login
    case list
    case clean
    case capture
    case ocr
    case export

    /// What BookPipeline runs for this command, for the book commands.
    public var pipelineCommand: BookPipeline.Command? {
      switch self {
      case .all: return .all
      case .capture: return .capture
      case .ocr: return .transcribe
      case .export: return .export
      case .login, .list, .clean: return nil
      }
    }
  }

  public struct Options: Equatable, Sendable {
    public var command: Command = .all
    public var asins: [String] = []
    /// As given; `nil` for the default (`defaultOutDir`).
    public var outDir: String?
    public var formats: [ExportFormat] = [.md]
    public var json = false
    public var limit: Int?
    public var concurrency: Int?
    public var forceCapture = false
    public var forceOcr = false
    public var keepPages = false
    /// Show the reader window during capture instead of hiding it.
    public var show = false

    public init() {}
  }

  public enum Parsed: Equatable, Sendable {
    case help
    case version
    case run(Options)
  }

  public struct UsageError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
  }

  /// cli.ts ASIN_REGEX. An ASIN is also a directory name, so without this a
  /// typo like `clean ..` would resolve outside the book folder.
  static let asinPattern = #"^[A-Z0-9]+$"#

  /// Commands the Node tool has and this one deliberately does not.
  static let nodeOnlyCommands: [String: String] = [
    "serve": "on a Mac, open Kindle Export.app instead",
    "setup": "this tool needs no setup; sign in with 'kindle-export login'",
  ]

  static let nodeOnlyOptions: [String: String] = [
    "--model": "pages are read on this Mac with Apple Vision",
    "--profile-dir": "the Amazon session is the Kindle Export app's",
    "--otp": "sign-in happens in a window, which asks for codes itself",
    "--port": "there is no web server; open Kindle Export.app instead",
  ]

  public static func parse(_ argv: [String]) throws -> Parsed {
    var options = Options()
    var positional: [String] = []
    var force = false
    var index = 0

    func value(for flag: String) throws -> String {
      index += 1
      guard index < argv.count else { throw UsageError("\(flag) requires a value") }
      return argv[index]
    }

    while index < argv.count {
      let arg = argv[index]
      switch arg {
      case "-h", "--help":
        return .help
      case "-v", "--version":
        return .version
      case "--out-dir":
        let dir = try value(for: arg)
        // A blank path would become the current directory by accident.
        guard !dir.trimmingCharacters(in: .whitespaces).isEmpty else {
          throw UsageError("--out-dir requires a folder")
        }
        options.outDir = dir
      case "--format":
        options.formats = try parseFormats(try value(for: arg))
      case "--json":
        options.json = true
      case "--limit":
        options.limit = try parsePositiveInteger(arg, try value(for: arg))
      case "--concurrency":
        // Checked here, not when transcription starts — after a capture that
        // can take an hour.
        options.concurrency = try parsePositiveInteger(arg, try value(for: arg))
      case "--force":
        force = true
      case "--force-capture", "--force-extract":
        options.forceCapture = true
      case "--force-ocr":
        options.forceOcr = true
      case "--force-export":
        // Export always rewrites its output; accepted so scripts written for
        // the Node tool keep working.
        break
      case "--keep-pages":
        options.keepPages = true
      case "--show":
        options.show = true
      default:
        if let why = nodeOnlyOptions[arg] {
          throw UsageError("\(arg) is only in the Node version of kindle-export (\(why))")
        }
        if arg.hasPrefix("-") { throw UsageError("unknown option: \(arg)") }
        positional.append(arg)
      }
      index += 1
    }

    if let first = positional.first?.lowercased() {
      if let command = Command(rawValue: first), command != .all {
        options.command = command
        positional.removeFirst()
      } else if let why = nodeOnlyCommands[first] {
        throw UsageError("'\(first)' is only in the Node version of kindle-export (\(why))")
      }
    }

    for raw in positional {
      let asin = raw.trimmingCharacters(in: .whitespaces).uppercased()
      if asin.isEmpty { continue }
      guard asin.range(of: asinPattern, options: .regularExpression) != nil else {
        throw UsageError("invalid ASIN: \(asin)")
      }
      options.asins.append(asin)
    }

    switch options.command {
    case .capture, .ocr, .export:
      if options.asins.isEmpty {
        throw UsageError("'\(options.command.rawValue)' needs at least one ASIN")
      }
    case .login, .list:
      if !options.asins.isEmpty {
        throw UsageError("'\(options.command.rawValue)' takes no ASINs")
      }
    case .all, .clean:
      break
    }

    if force {
      options.forceCapture = true
      options.forceOcr = true
    }
    return .run(options)
  }

  static func parseFormats(_ raw: String) throws -> [ExportFormat] {
    var formats: [ExportFormat] = []
    for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
      let name = part.trimmingCharacters(in: .whitespaces).lowercased()
      guard let format = ExportFormat(rawValue: name) else {
        throw UsageError("unknown format: \(name) (expected md or pdf)")
      }
      if !formats.contains(format) { formats.append(format) }
    }
    return formats
  }

  /// Strict where Int() on a prefix wouldn't be: `8x`, `1.5`, `0` and `-3`
  /// are all refused, by the flag that caused them (cli.ts parsePositiveInteger).
  static func parsePositiveInteger(_ flag: String, _ raw: String) throws -> Int {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
      let value = Int(trimmed), value > 0
    else { throw UsageError("\(flag) requires a positive whole number") }
    return value
  }

  // MARK: - defaults

  /// Where books go unless `--out-dir` says otherwise: the app's own folder,
  /// so a book started in the terminal shows up in the app and the other way
  /// round (the book lock keeps the two from working on one book at once).
  /// `KINDLE_EXPORT_OUT_DIR` moves both, as it does for the app.
  public static func defaultOutDir(environment: [String: String]) -> URL {
    AppEnvironment.standard(environment: environment).outDir
  }

  public static func resolveOutDir(_ options: Options, environment: [String: String], cwd: URL)
    -> URL
  {
    guard let given = options.outDir else { return defaultOutDir(environment: environment) }
    let expanded = (given as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: cwd).standardizedFileURL
  }

  /// The app's version when this tool runs from inside Kindle Export.app
  /// (the two can't disagree), the compiled-in one otherwise.
  public static func resolvedVersion(bundle: Bundle = .main) -> String {
    if bundle.bundleIdentifier == appBundleIdentifier,
      let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String, !short.isEmpty
    {
      return short
    }
    return version
  }

  // MARK: - help

  public static let help = """
    kindle-export — export Kindle books you own as markdown

    Usage
      kindle-export                        pick books from your library, then export
      kindle-export <ASIN...>              capture, transcribe and export (resumes)
      kindle-export login                  sign in to Amazon (in a window)
      kindle-export list                   list the books in your Kindle library
      kindle-export clean [ASIN...]        delete working files, keeping the text
      kindle-export capture <ASIN...>      capture page images only
      kindle-export ocr <ASIN...>          transcribe captured pages only
      kindle-export export <ASIN...>       write markdown/PDF from transcribed text only

    Options
      --format <md|pdf>      output format(s), comma separated (default: md)
      --json                 with 'list', print JSON instead of a table
      --limit <n>            with 'list', stop after this many books
      --out-dir <dir>        where books are written
                             (default: ~/Documents/Kindle Export, the app's folder)
      --concurrency <n>      pages transcribed in parallel (default: 16)
      --force                redo every stage, ignoring existing output
      --force-capture        redo page capture
      --force-ocr            redo transcription
      --keep-pages           keep page images instead of deleting them once
                             every page has been transcribed
      --show                 show the Kindle reader window while capturing
      -h, --help             show this help
      -v, --version          show the version

    This is the command-line side of Kindle Export.app. It uses the app's
    Amazon sign-in and the app's books folder, so a book started in one can be
    finished in the other. Pages are read on this Mac with Apple's Vision
    framework — free, offline, no API key.

    Sign-in: if Amazon wants you to sign in, its page opens in a window; the
    session is the app's, so signing in either place signs in both.

    Page images are deleted once a book is fully transcribed, since
    re-capturing costs time rather than data. Pass --keep-pages to hold on to
    them. Ctrl-C stops cleanly; running the same command again resumes.

    Examples
      kindle-export                        pick from a list of your books
      kindle-export list --json
      kindle-export B01H4G2J1U
      kindle-export B01H4G2J1U B07PPW5V9C --force-ocr
      kindle-export export B01H4G2J1U --format md,pdf
    """
}
