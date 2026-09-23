import AppKit
import Foundation
import KindleExportKit

/// One run of `book-export`: the command, its output, Ctrl-C, and — for
/// the commands that use the reader — the windows.
@MainActor
final class Runner: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let options: CommandLineOptions.Options
  let outDir: URL

  private var work: Task<Void, Never>?
  /// Books are being worked on: the first Ctrl-C stops them properly.
  private var busyWithBooks = false
  private var stopping = false
  private var signalSources: [DispatchSourceSignal] = []

  private var backendIfMade: NativeBackend?
  private var signInWindow: NSWindow?
  private var signInView: SignInView?
  /// Whoever had focus before the sign-in window took it (the terminal).
  private var previousApp: NSRunningApplication?

  static let debug = ProcessInfo.processInfo.environment["KINDLE_EXPORT_DEBUG"] == "1"

  init(options: CommandLineOptions.Options, outDir: URL) {
    self.options = options
    self.outDir = outDir
  }

  /// Library reads, sign-in and capture drive the reader's web view, which
  /// needs an application and windows; the other stages don't.
  var usesAppKit: Bool {
    switch options.command {
    case .all, .capture, .login, .list: return true
    case .ocr, .export, .clean: return false
    }
  }

  // MARK: - lifecycle

  func applicationDidFinishLaunching(_: Notification) {
    installMenu()
    start()
  }

  func start() {
    installSignalHandlers()
    work = Task { @MainActor in
      let code = await self.run()
      exit(code)
    }
  }

  /// Ctrl-C (or SIGTERM): the first one stops the book in progress the way
  /// the app's Cancel does — capture records "interrupted", the book lock is
  /// released, a re-run resumes — and the second quits at once.
  private func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.interrupt() }
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func interrupt() {
    guard busyWithBooks, !stopping else { exit(130) }
    stopping = true
    Terminal.error("\nStopping... (press Ctrl-C again to quit at once)")
    work?.cancel()
  }

  /// "Quit" from the Dock menu or AppleScript: the same as Ctrl-C.
  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    guard busyWithBooks else { return .terminateNow }
    if !stopping { interrupt() }
    return .terminateCancel
  }

  /// This process has the app's bundle identity, so while it runs, opening
  /// Book Export for Kindle from Finder or the Dock finds *it* and merely reopens it —
  /// the app would never start. Start the real app instead.
  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    guard Bundle.main.bundleIdentifier == CommandLineOptions.appBundleIdentifier else {
      return true
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    return false
  }

  // MARK: - commands

  private func run() async -> Int32 {
    switch options.command {
    case .login: return await login()
    case .list: return await list()
    case .clean: return await clean()
    case .all, .capture, .ocr, .export:
      var asins = options.asins
      if asins.isEmpty {
        // Naming no book is a request to choose one, not a usage error.
        switch await pick() {
        case .books(let picked): asins = picked
        case .exit(let code): return code
        }
      }
      return await processBooks(asins)
    }
  }

  private func login() async -> Int32 {
    Terminal.print("Checking your Amazon sign-in...")
    if await backend.signIn() {
      Terminal.print("Signed in to Amazon. Book Export for Kindle.app shares this sign-in.")
      return 0
    }
    Terminal.error("Could not confirm the sign-in (the window was closed, or it timed out).")
    return 1
  }

  private func list() async -> Int32 {
    let books: [LibraryBook]
    do {
      books = try await library(limit: options.limit)
    } catch {
      Terminal.error("book-export: \(libraryErrorMessage(error))")
      return 1
    }
    if options.json {
      Terminal.print(CommandLineOutput.listJSON(books))
    } else {
      CommandLineOutput.listLines(books).forEach(Terminal.print)
    }
    return 0
  }

  enum Picked {
    case books([String])
    case exit(Int32)
  }

  /// cli.ts `selectFromLibrary`, as a numbered list: filter first when the
  /// library is long, then type the numbers.
  private func pick() async -> Picked {
    guard Terminal.isInteractive else {
      Terminal.error(
        "No ASINs given and no terminal to prompt on. Pass ASINs directly, or run: book-export list"
      )
      return .exit(1)
    }

    Terminal.print("Reading your Kindle library...")
    let books: [LibraryBook]
    do {
      books = try await library(limit: nil)
    } catch {
      Terminal.error("book-export: \(libraryErrorMessage(error))")
      return .exit(1)
    }
    guard !books.isEmpty else {
      Terminal.print("No books found in your Kindle library.")
      return .exit(0)
    }

    var shortlist = books
    if books.count > CommandLineOutput.filterPromptThreshold {
      guard
        let needle = await Terminal.prompt(
          "\(books.count) books. Filter by title or author (blank for all): ")
      else { return .exit(1) }
      shortlist = CommandLineOutput.filter(books, by: needle)
      if shortlist.isEmpty {
        Terminal.print("Nothing matched \"\(needle.trimmingCharacters(in: .whitespaces))\".")
        return .exit(0)
      }
    }

    CommandLineOutput.pickerLines(shortlist).forEach(Terminal.print)
    while true {
      guard
        let answer = await Terminal.prompt(
          "Books to export (e.g. 1 3 5-7, or all; blank to cancel): ")
      else { return .exit(1) }
      do {
        let picked = try CommandLineOutput.parseSelection(answer, count: shortlist.count)
        return picked.isEmpty ? .exit(0) : .books(picked.map { shortlist[$0].asin })
      } catch {
        Terminal.error(Terminal.describe(error))
      }
    }
  }

  private func processBooks(_ asins: [String]) async -> Int32 {
    guard let command = options.command.pipelineCommand else { return 2 }
    let stored = AppConfig.load(AppEnvironment.standard().configURL)
    let pipelineOptions = BookPipeline.Options(
      command: command, formats: options.formats, keepPages: options.keepPages,
      forceCapture: options.forceCapture, forceOcr: options.forceOcr,
      concurrency: options.concurrency ?? stored.concurrency ?? VisionOCR.defaultConcurrency)
    // Transcribing and exporting need no reader, so no web view is made.
    let offline =
      usesAppKit
      ? nil : BookPipeline(outDir: outDir, ownerName: CommandLineOptions.programName)

    busyWithBooks = true
    defer { busyWithBooks = false }

    var failures: [String] = []
    var incomplete: [String] = []
    var interrupted = false

    for asin in asins {
      if Task.isCancelled {
        interrupted = true
        break
      }
      let renderer = EventPrinter(asin: asin)
      do {
        let result: BookResult
        if let offline {
          result = try await offline.process(asin: asin, options: pipelineOptions) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { renderer.print(event) } }
          }
        } else {
          result = try await backend.processBook(asin: asin, options: pipelineOptions) { event in
            renderer.print(event)
          }
        }

        // Short of what was asked without anything throwing — a capture
        // that stopped early, pages with no text — is still not success.
        if result.fellShort(command) { incomplete.append(asin) }

        if command == .all || command == .export {
          let outputs = result.outputs.map(\.path).joined(separator: ", ")
          Terminal.print(
            "[\(asin)] done in \(CommandLineOutput.duration(result.duration)): \(outputs)")
        }
      } catch {
        // Whatever a cancelled capture throws on its way out, it was Ctrl-C.
        if error is CancellationError || Task.isCancelled {
          interrupted = true
          Terminal.error("[\(asin)] stopped — run the same command again to carry on")
          break
        }
        failures.append(asin)
        Terminal.error("[\(asin)] failed: \(Terminal.describe(error))")
      }
    }

    if !failures.isEmpty {
      Terminal.error("\n\(failures.count) of \(asins.count) failed")
    }
    if !incomplete.isEmpty {
      Terminal.error(
        "\(incomplete.count) book(s) are missing part of the book: "
          + incomplete.joined(separator: ", "))
    }
    if interrupted { return 130 }
    return failures.isEmpty && incomplete.isEmpty ? 0 : 1
  }

  // MARK: - clean

  /// cli.ts `clean`: render data always, page images only once every
  /// captured page has text — otherwise a retry would silently become a
  /// re-capture.
  private func clean() async -> Int32 {
    let asins = options.asins.isEmpty ? bookFolders() : options.asins
    guard !asins.isEmpty else {
      Terminal.print("No books found in \(outDir.path)")
      return 0
    }
    let core: PipelineCore
    do {
      core = try PipelineCore()
    } catch {
      Terminal.error("book-export: \(Terminal.describe(error))")
      return 1
    }

    var freed: Int64 = 0
    var failed = false
    for asin in asins {
      let store = BookStore(outDir: outDir, asin: asin)
      do {
        // Under the book lock: what this deletes is a run's input.
        freed += try await BookLock.withLock(
          bookDir: store.bookDir, command: "\(CommandLineOptions.programName) clean"
        ) {
          try cleanBook(store, core: core)
        }
      } catch let busy as BookBusyError {
        Terminal.print("[\(asin)] skipped: \(busy.localizedDescription)")
      } catch {
        failed = true
        Terminal.error("[\(asin)] failed: \(Terminal.describe(error))")
      }
    }
    Terminal.print("\nFreed \(formatBytes(freed)) in total.")
    return failed ? 1 : 0
  }

  private func cleanBook(_ store: BookStore, core: PipelineCore) throws -> Int64 {
    let render = try store.cleanRenderData()
    var pages: Int64 = 0
    if !options.keepPages, let metadata = store.readMetadata() {
      let completeness = try core.bookCompleteness(metadata: metadata, content: store.readContent())
      if completeness.capturedPages > 0, completeness.missingPages.isEmpty {
        pages = try store.cleanPageImages().freed
      } else if completeness.transcribedPages > 0 {
        Terminal.print("[\(store.asin)] keeping page images: transcription is incomplete")
      }
    }
    let total = render.freed + pages
    if total > 0 { Terminal.print("[\(store.asin)] freed \(formatBytes(total))") }
    return total
  }

  /// The book folders in outDir. Only ASIN-named ones: the default folder is
  /// the app's, in Documents, where a person may keep other things.
  private func bookFolders() -> [String] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: outDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    return entries.filter {
      (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        && $0.lastPathComponent.range(of: #"^[A-Z0-9]+$"#, options: .regularExpression) != nil
    }.map(\.lastPathComponent).sorted()
  }

  // MARK: - library

  /// The library; if Amazon wants a sign-in and someone is at the terminal,
  /// show it once and try again.
  private func library(limit: Int?) async throws -> [LibraryBook] {
    do {
      return try await backend.fetchLibrary(limit: limit)
    } catch LibraryService.LibraryError.notSignedIn where Terminal.isInteractive {
      Terminal.error("Amazon wants you to sign in — its page is opening in a window.")
      guard await backend.signIn() else { throw LibraryService.LibraryError.notSignedIn }
      return try await backend.fetchLibrary(limit: limit)
    }
  }

  private func libraryErrorMessage(_ error: Error) -> String {
    if case LibraryService.LibraryError.notSignedIn = error {
      return "Not signed in to Amazon. Run: book-export login"
    }
    return Terminal.describe(error)
  }

  // MARK: - the reader

  /// Made on first use: `clean`, `ocr` and `export` never need it.
  private var backend: NativeBackend {
    if let backendIfMade { return backendIfMade }

    let session: ReaderSession
    if options.show {
      // --show: an ordinary window, left on screen for the whole run.
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: ReaderSession.viewportSize),
        styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
      session = ReaderSession(window: window)
      window.title = "Book Export for Kindle — reader"
    } else {
      // The app's invisible host window: renders, takes synthesized input,
      // shows nothing.
      session = ReaderSession()
    }

    let made = NativeBackend(
      outDir: outDir, session: session, ownerName: CommandLineOptions.programName)
    made.log = { line in
      // The reader's own diagnostics are for debugging; the capture's
      // narration ("[ASIN] reached the end of the book …") is the progress.
      if line.hasPrefix("reader: ") {
        if Runner.debug { Terminal.error(line) }
      } else {
        Terminal.print(line)
      }
    }
    made.signInNotice = "Amazon needs you to sign in — its sign-in page is open in a window"
    made.allowsSignIn = Terminal.isInteractive
    made.onPlacementChange = { [weak self] placement in self?.place(placement) }
    if options.show {
      session.hostWindow.center()
      session.hostWindow.orderFrontRegardless()
    }
    backendIfMade = made
    return made
  }

  /// Show Amazon's sign-in, or put it away (NativeBackend decides when).
  private func place(_ placement: NativeBackend.ReaderPlacement) {
    guard let backend = backendIfMade else { return }
    let session = backend.session
    switch placement {
    case .signIn:
      previousApp = NSWorkspace.shared.frontmostApplication
      // A Dock icon while a window needs the person: it's how they find it.
      NSApp.setActivationPolicy(.regular)
      if options.show {
        session.show()
      } else {
        let (window, view) = signInWindowAndView()
        session.present(in: view.readerSlot)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.webView)
      }
      NSApp.activate(ignoringOtherApps: true)

    case .background:
      // NativeBackend takes the web view back to its host itself.
      signInWindow?.orderOut(nil)
      NSApp.setActivationPolicy(.accessory)
      if let previousApp, previousApp.processIdentifier != getpid() {
        previousApp.activate()
      }
      previousApp = nil
    }
  }

  private func signInWindowAndView() -> (NSWindow, SignInView) {
    if let signInWindow, let signInView { return (signInWindow, signInView) }
    let frame = NSRect(x: 0, y: 0, width: 960, height: 760)
    let window = NSWindow(
      contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Book Export for Kindle — Sign in"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 520, height: 480)
    let view = SignInView(frame: frame)
    view.onCancel = { [weak self] in self?.backendIfMade?.cancelSignIn() }
    window.contentView = view
    window.delegate = self
    signInWindow = window
    signInView = view
    return (window, view)
  }

  /// Closing the sign-in window is Cancel; the backend then hides it.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === signInWindow else { return true }
    backendIfMade?.cancelSignIn()
    return false
  }

  /// Without an Edit menu, ⌘V does nothing in Amazon's sign-in form.
  private func installMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit book-export", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(NSMenuItem.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    NSApp.mainMenu = main
  }
}

/// A book's events as terminal lines (CommandLineOutput.EventRenderer),
/// holding the renderer's throttling state on the main actor.
@MainActor
final class EventPrinter {
  private var renderer: CommandLineOutput.EventRenderer

  init(asin: String) { renderer = CommandLineOutput.EventRenderer(asin: asin) }

  func print(_ event: PipelineEvent) {
    for line in renderer.lines(for: event) { Terminal.write(line) }
  }
}
