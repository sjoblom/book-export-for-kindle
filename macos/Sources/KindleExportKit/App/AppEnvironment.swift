import AppKit
import Foundation

/// What the app does to Amazon and to books, as far as `AppModel` is
/// concerned. `NativeBackend` does it with the reader web view, CaptureEngine
/// and BookPipeline; the tests use a stand-in, as serve.test.ts mocks Chrome
/// and the pipeline.
///
/// The model calls at most one of these at a time (see `AppModel.busy`): they
/// all drive the same web view.
@MainActor
public protocol AppBackend: AnyObject {
  /// Read the signed-in account's library. Throws
  /// `LibraryService.LibraryError.notSignedIn` when nobody is signed in.
  func fetchLibrary() async throws -> [LibraryBook]

  /// Show Amazon's sign-in and wait for the person to complete it. `true`
  /// once Amazon confirms the session; `false` when they closed the window or
  /// gave up (session.ts `interactiveLogin`).
  func signIn() async -> Bool

  /// Run one book through capture → transcribe → export (pipeline.ts
  /// `processBook`), reporting events on the main actor as they happen.
  func processBook(
    asin: String, options: BookPipeline.Options,
    emit: @escaping @MainActor @Sendable (PipelineEvent) -> Void
  ) async throws -> BookResult
}

/// Where the app keeps things, and the few ways it touches the desktop.
public struct AppEnvironment {
  /// One folder per book.
  public var outDir: URL
  /// `~/.kindle-export/config.json`, shared with the CLI.
  public var configURL: URL
  /// Where the last library read is kept for the next launch.
  public var libraryCacheDir: URL
  /// Downloads land here, never overwriting anything.
  public var downloadsDir: URL
  /// Open a folder in Finder (`POST /api/reveal`).
  public var openFolder: @MainActor (URL) -> Void
  /// Show a saved file selected in Finder (downloads).
  public var revealFile: @MainActor (URL) -> Void
  /// State pushes are coalesced over this long (serve.ts BROADCAST_DEBOUNCE_MS).
  public var broadcastDelay: TimeInterval

  public init(
    outDir: URL, configURL: URL, libraryCacheDir: URL, downloadsDir: URL,
    openFolder: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
    revealFile: @escaping @MainActor (URL) -> Void = {
      NSWorkspace.shared.activateFileViewerSelecting([$0])
    },
    broadcastDelay: TimeInterval = 0.15
  ) {
    self.outDir = outDir
    self.configURL = configURL
    self.libraryCacheDir = libraryCacheDir
    self.downloadsDir = downloadsDir
    self.openFolder = openFolder
    self.revealFile = revealFile
    self.broadcastDelay = broadcastDelay
  }

  /// The installed app's places.
  ///
  /// - Books: `~/Documents/Kindle Export`, as the Node-based app used.
  /// - Settings: `~/.kindle-export/config.json`, shared with the CLI, so
  ///   "also PDF" means the same on both sides.
  /// - Library cache: `~/Library/Application Support/Kindle Export/`. The Node
  ///   tool keeps it inside the Chrome profile so the list goes with the
  ///   signed-in account; the app's session lives in WebKit's own data store
  ///   (`WKWebsiteDataStore.default()`, managed by WebKit, not ours to write
  ///   into), so the per-app Application Support folder is the equivalent
  ///   place — per user, per app, not synced, and removed with the app's data.
  public static func standard() -> AppEnvironment {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let support =
      (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? home.appendingPathComponent("Library/Application Support")
    let downloads =
      (try? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? home.appendingPathComponent("Downloads")
    return AppEnvironment(
      outDir: home.appendingPathComponent("Documents/Kindle Export", isDirectory: true),
      configURL: home.appendingPathComponent(".kindle-export/config.json"),
      libraryCacheDir: support.appendingPathComponent("Kindle Export", isDirectory: true),
      downloadsDir: downloads)
  }
}

/// `~/.kindle-export/config.json` (src/config.ts), read and written the way
/// the CLI does: unknown keys are kept, bad values are ignored on read.
public enum AppConfig {
  public struct Settings: Equatable, Sendable {
    public var alsoPdf: Bool?
    public var concurrency: Int?
  }

  static func loadRaw(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }

  /// config.ts `loadConfig`, for the two settings the app uses.
  public static func load(_ url: URL) -> Settings {
    let raw = loadRaw(url)
    var settings = Settings()
    if let value = raw["alsoPdf"] as? NSNumber, isBool(value) { settings.alsoPdf = value.boolValue }
    if let value = raw["concurrency"] as? NSNumber, !isBool(value),
      value.doubleValue == value.doubleValue.rounded(), value.doubleValue >= 1,
      value.doubleValue <= Double(Int32.max)
    {
      settings.concurrency = value.intValue
    }
    return settings
  }

  /// Set `alsoPdf`, keeping every other key (an API key, outDir, …) as it was.
  /// The directory is 0700 and the file 0600, as config.ts writes them: the
  /// CLI keeps an OpenAI key here.
  public static func save(alsoPdf: Bool, to url: URL) throws {
    var raw = loadRaw(url)
    raw["alsoPdf"] = alsoPdf
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    try fm.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var data = try JSONSerialization.data(
      withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try writeFileAtomically(
      data, to: url, tempName: ".\(url.lastPathComponent).\(getpid()).tmp", permissions: 0o600)
  }

  static func isBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }
}

/// Where the page the app shows (`app.html`, the UI of src/serve-page.ts
/// rendered for the bridge) is found: the app bundle's Resources, then
/// `KINDLE_APP_HTML`, then the checkout's `dist-core/` (`swift run`).
public enum AppPage {
  public static let fileName = "app.html"

  public static func candidates() -> [URL] {
    var urls: [URL] = []
    if let resources = Bundle.main.resourceURL {
      urls.append(resources.appendingPathComponent(fileName))
    }
    if let env = ProcessInfo.processInfo.environment["KINDLE_APP_HTML"] {
      urls.append(URL(fileURLWithPath: env))
    }
    // …/macos/Sources/KindleExportKit/App/AppEnvironment.swift → repo root
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    urls.append(repo.appendingPathComponent("dist-core/\(fileName)"))
    return urls
  }

  public static func locate() -> URL? {
    candidates().first { FileManager.default.fileExists(atPath: $0.path) }
  }
}
