import AppKit
import Foundation

/// Captures one book's page images and metadata.json from the Kindle Cloud
/// Reader — a port of extract-kindle-book.ts `extractBook`.
///
/// Browser driving lives here and in `ReaderSession`; every decision about
/// where we are and when to stop (footer parsing, page normalization, the
/// termination and recovery rules, the metadata built from the reader's
/// responses) is made by KindleCore through `JSCore`, the same code the CLI
/// runs, so the two captures stop in the same places.
@MainActor
public final class CaptureEngine {
  public struct Options: Sendable {
    public var asin: String
    /// Root holding one folder per ASIN (the CLI's `out`).
    public var outDir: URL
    /// Put the reader back where the person was reading when done.
    public var restoreReadingPosition = true
    /// Test hook (`KINDLE_EXPORT_SIMULATE_STALL_AT_PAGE`): pretend the reader
    /// stalls once, on the first screen at or past this page.
    public var simulateStallAtPage: Int?

    public init(asin: String, outDir: URL) {
      self.asin = asin
      self.outDir = outDir
      if let value = ProcessInfo.processInfo.environment["KINDLE_EXPORT_SIMULATE_STALL_AT_PAGE"] {
        simulateStallAtPage = Int(value)
      }
    }
  }

  public struct Progress: Sendable, Equatable {
    /// Screens saved so far.
    public var screens: Int
    /// The page the capture has reached.
    public var page: Int
    /// Content pages the book claims to have (0 until known).
    public var totalContentPages: Int
  }

  public enum Event: Sendable {
    case message(String)
    case progress(Progress)
    /// Amazon wants a sign-in. The sign-in handler (if any) runs next.
    case needsSignIn
  }

  public enum CaptureError: Error, CustomStringConvertible {
    /// Amazon asked for a sign-in and there was no handler, or it failed.
    case needsSignIn
    case failed(String)

    public var description: String {
      switch self {
      case .needsSignIn: return "Amazon needs you to sign in"
      case .failed(let message): return message
      }
    }
  }

  public let session: ReaderSession
  public let options: Options
  let core: JSCore

  /// Events as they happen, on the main actor.
  public var onEvent: ((Event) -> Void)?

  /// Called when Amazon shows its sign-in page: show the window, wait for the
  /// person, hide it again. Throw to give up. Without one, a capture that
  /// hits the sign-in page fails with `.needsSignIn`. Never scripted.
  public var signInHandler: ((ReaderSession) async throws -> Void)?

  // Selectors (extract-kindle-book.ts).
  static let mainImageSelector = "#kr-renderer .kg-full-page-img img"
  static let nextChevronSelector = ".kr-chevron-container-right"
  static let previousChevronSelector = ".kr-chevron-container-left"
  static let footerSelector = "ion-footer ion-title"
  static let settingsButton = ElementSpec(
    #"ion-button[aria-label="Reader settings"], button[aria-label="Reader settings"]"#)
  static let goToModalInput = ElementSpec(
    #"ion-modal.go-to-modal.show-modal input[placeholder="page number"], ion-modal.go-to-modal.show-modal input[placeholder*="location" i], ion-modal input[placeholder="page number"], ion-modal input[placeholder*="location" i]"#
  )
  static let goToModalGoButton = ElementSpec.hasText(
    #"ion-modal.go-to-modal.show-modal ion-button[item-i-d="go-to-modal-go-button"], ion-modal ion-button[item-i-d="go-to-modal-go-button"], ion-modal button, ion-modal ion-button"#,
    "Go")

  private var bookReaderURL: URL { URL(string: "https://read.amazon.com/?asin=\(options.asin)")! }
  private var bookDir: URL { options.outDir.appendingPathComponent(options.asin) }
  private var metadataURL: URL { bookDir.appendingPathComponent("metadata.json") }

  // Capture state.
  private var document = MetadataDocument()
  private var locationMap: RawJSON?
  private var nav: BookNav?
  private var pages: [CapturedScreen] = []
  private var capture: CaptureState?
  private var capturedScreenHashes = Set<String>()
  private var resume: ResumeState?
  private var simulatedStallDone = false
  /// Which input turns pages; switched when one stalls (see `turnPage`).
  private var preferredTurn: TurnMethod = .key

  enum TurnMethod { case key, mouse }

  public init(session: ReaderSession, options: Options, core: JSCore) {
    self.session = session
    self.options = options
    self.core = core
  }

  // MARK: - logging

  private func info(_ message: String) { onEvent?(.message(message)) }

  // MARK: - run

  /// Capture the book. Returns how the capture ended (also in metadata.json).
  /// Cancelling the task stops at the next await; what was captured so far
  /// stays on disk, recorded as `interrupted`.
  @discardableResult
  public func run() async throws -> CaptureState {
    let fm = FileManager.default
    try fm.createDirectory(
      at: bookDir.appendingPathComponent(CaptureSupport.pageImagesDir),
      withIntermediateDirectories: true)

    session.asin = options.asin
    session.clearCaptures()
    session.interceptor = { [weak self] in _ = await self?.dismissPossibleAlert() }
    defer { session.interceptor = nil }

    do {
      return try await captureBook()
    } catch {
      // Everything captured so far is already on disk, marked incomplete;
      // make sure the file reflects the last screen.
      if capture != nil { try? document.write(to: metadataURL) }
      throw error
    }
  }

  private func captureBook() async throws -> CaptureState {
    try await openReader(timeout: 30)

    // Wait for the book to render before touching the reader UI.
    info("Waiting for book reader to load...")
    if !(try await session.waitFor(ElementSpec(Self.mainImageSelector, visible: false), timeout: 60)) {
      info("Main reader content may not have loaded, continuing anyway...")
    }

    _ = await dismissPossibleAlert()
    await ensureFixedHeaderUI()
    try await updateSettings()

    // Record the initial page navigation so we can reset back to it later.
    let initialPageNav = await readPageNav()

    try await buildMetadata()
    guard let nav, nav.totalNumContentPages > 0 else {
      throw CaptureError.failed("No content pages found")
    }
    let totalContentPages = nav.totalNumContentPages
    let padding = CaptureSupport.pageNumberPadding(totalContentPages: totalContentPages)

    // Recorded before the first page and updated in place, so the metadata
    // written after every page says "incomplete" until the loop reaches an
    // actual end.
    capture = CaptureState(
      complete: false, reason: "interrupted", lastPage: 0, totalContentPages: totalContentPages)
    try writeMetadata()

    try await goToPage(nav.startContentPage)

    info(
      "reading \(totalContentPages) content pages out of \(nav.totalNumPages) total pages...")
    emitProgress(page: 0)

    var done = false
    while !done {
      try Task.checkCancellation()
      let pageNav = await readPageNav()
      let index = pages.count
      let currentPage = try core.call(
        "normalizePageNumber", pageNav, locationMap, index + 1, as: Int.self)
      let footerValue = pageNav?.page ?? pageNav?.location

      if let stop = try core.call(
        "shouldStopBeforeCapture",
        BeforeCaptureInput(
          hasPageNav: pageNav != nil, currentPage: currentPage,
          totalContentPages: totalContentPages),
        as: CaptureStop?.self)
      {
        if stop.reason == "no-page-nav" { info("lost track of the page position (index \(index))") }
        if try await recoverOrStop(stop) { continue }
        break
      }
      guard let pageNav else { throw CaptureError.failed("expected a page nav") }

      guard let src = await session.imageSource(Self.mainImageSelector) else {
        throw CaptureError.failed("no page image (index \(index); page \(currentPage))")
      }
      let blob = try await takeBlob(src)
      guard let blob else {
        let evicted = session.blobs.recentlyEvicted.first { $0.url == src }
        info(
          "blob store: \(session.blobs.count) waiting, \(session.blobs.consumedCount) consumed; "
            + (evicted.map { "this one arrived at consumption \($0.arrivedAt) and was aged out" }
              ?? "this one never arrived"))
        throw CaptureError.failed(
          "no blob found for src: \(src) (index \(index); page \(currentPage))")
      }
      let image = try CaptureSupport.downscaledPNG(blob.data)
      let screenHash = CaptureSupport.sha256Hex(image)

      var skipScreen = false
      if let current = resume {
        let decision = try core.call(
          "resumeScreenDecision",
          ResumeScreenInput(
            resume: current, alreadyCaptured: capturedScreenHashes.contains(screenHash),
            currentPage: currentPage, capturedAny: !pages.isEmpty),
          as: ResumeScreenDecision.self)

        switch decision.type {
        case "lost-place":
          info(
            "after reloading, the reader showed page \(currentPage) instead of page "
              + "\(current.page); screens in between may be missing")
          resume = nil
          // The same stall again, as far as the budget is concerned.
          guard let stalled = capture?.recoveries?.last?.reason else {
            throw CaptureError.failed("expected a recorded recovery while resuming")
          }
          if try await recoverOrStop(CaptureStop(complete: false, reason: stalled)) { continue }
          done = true
          continue
        case "skip":
          resume?.skipped += 1
          skipScreen = true
        default:
          if decision.possibleDuplicates == true {
            info(
              "after reloading, page \(currentPage) rendered differently from before, "
                + "so some of its screens may be captured twice")
          } else {
            info(
              "resumed capturing after the reload at page \(currentPage) "
                + "(\(current.skipped) screens already captured were skipped)")
          }
          resume = nil
        }
      }

      if !skipScreen {
        let screenshot = CaptureSupport.screenshotPath(
          index: index, page: currentPage, padding: padding)
        try image.write(to: bookDir.appendingPathComponent(screenshot))
        let chunk = CapturedScreen(index: index, page: currentPage, screenshot: screenshot)
        pages.append(chunk)
        try document.appendPage(chunk)
        capture?.lastPage = currentPage
        try writeMetadata()
        capturedScreenHashes.insert(screenHash)
        if index == 0 || (index + 1) % 100 == 0 {
          info("captured \(index + 1) page images; current page/location \(currentPage)")
        }
        emitProgress(page: currentPage)
      }

      // Turning the page is the only thing that tells the last screen of the
      // last numbered page from the first; the footer only decides how long
      // to spend trying.
      let onLast = try core.call(
        "isOnLastNumberedPage", FooterPosition(value: footerValue, total: pageNav.total),
        as: Bool.self)
      let maxAttempts = try core.call("maxNavigationAttempts", onLast, as: Int.self)
      var observations: [NavigationResult] = []

      while true {
        try await sleep(0.1)

        let clickTimeout = try core.call("chevronClickTimeoutMs", onLast, as: Double.self)
        let clickFailed = !(try await turnPage(
          from: src, chevronTimeout: clickTimeout / 1000, quiet: onLast))
        let timeout = try core.call(
          "navigationTimeoutMs",
          NavigationTimeoutInput(onLastNumberedPage: onLast, clickFailed: clickFailed),
          as: Double.self)
        let navigated = try await waitForSourceChange(from: src, timeout: timeout / 1000)

        if let stallAt = options.simulateStallAtPage, currentPage >= stallAt, !simulatedStallDone {
          info("simulating a reader stall at page \(currentPage)")
          observations += Array(repeating: .stalled, count: maxAttempts)
          simulatedStallDone = true
        } else if navigated {
          observations.append(.navigated)
        } else {
          let result = try await classifyFailedTurn()
          observations.append(result)
          switch result {
          case .signedOut:
            info("Amazon signed the reader out (page \(currentPage))")
          case .readerLost:
            info("the reader is no longer showing the book (page \(currentPage))")
          case .stalled:
            // A method that didn't move a reader offering a next page: try
            // the other one on the next attempt.
            preferredTurn = preferredTurn == .key ? .mouse : .key
          default: break
          }
        }

        let action = try core.call(
          "shouldStopCapture",
          StopCaptureInput(
            observations: observations, onLastNumberedPage: onLast, maxAttempts: maxAttempts),
          as: CaptureAction.self)

        if action.type == "capture-next-screen" { break }
        if action.type == "retry-navigation" { continue }

        let stop = CaptureStop(complete: action.complete ?? false, reason: action.reason ?? "navigation-failed")
        if stop.reason == "end-of-book" {
          info("reached the end of the book (\(Self.describe(pageNav)))")
        } else {
          info("unable to navigate to next page (\(Self.describe(pageNav)))")
        }
        // A recovery leaves the reader on a screen not looked at yet, so the
        // outer loop captures (or recognises) it like any other.
        if !(try await recoverOrStop(stop)) { done = true }
        break
      }
    }

    try writeMetadata()
    guard let final = capture else { throw CaptureError.failed("capture state missing") }
    if !final.complete {
      info(
        "capture stopped early at page \(final.lastPage) of \(final.totalContentPages) (\(final.reason))")
    }
    info(metadataURL.path)

    if options.restoreReadingPosition, let initialPage = initialPageNav?.page {
      info("resetting back to initial page \(initialPage)...")
      // A courtesy: the capture is on disk, nothing here may fail the run.
      do { try await goToPage(initialPage) } catch is CancellationError {
      } catch { info("could not restore the reading position: \(error)") }
    }

    return final
  }

  /// What a page turn that rendered nothing new ran into. A missing chevron
  /// only means "last screen" while the reader is demonstrably still there,
  /// so the page image and the footer are looked at again now — the footer
  /// read before the turn says nothing about a reader that has since gone.
  /// KindleCore makes the call (`navigationResult`).
  private func classifyFailedTurn() async throws -> NavigationResult {
    let signedOut = session.isOnSignIn
    var evidence = NavigationEvidence(
      navigated: false, signedOut: signedOut, pageImage: false, footerReadable: false,
      nextPageUsable: false)
    if !signedOut {
      evidence.pageImage = await session.imageSource(Self.mainImageSelector) != nil
      evidence.footerReadable = await readPageNav() != nil
      // `nil` is a script that couldn't run (a navigation in flight): read
      // as "still offered", which can only ever lead to a retry.
      evidence.nextPageUsable =
        await session.run(
          ReaderScripts.usableChevron, ["selector": Self.nextChevronSelector], as: Bool.self)
        ?? true
    }
    return try core.call("navigationResult", evidence, as: NavigationResult.self)
  }

  private func emitProgress(page: Int) {
    onEvent?(
      .progress(
        Progress(
          screens: pages.count, page: page, totalContentPages: nav?.totalNumContentPages ?? 0)))
  }

  static func describe(_ nav: PageNav) -> String {
    if let page = nav.page { return "page \(page) of \(nav.total)" }
    if let location = nav.location { return "location \(location) of \(nav.total)" }
    return "total \(nav.total)"
  }

  // MARK: - reader lifecycle

  /// Load the reader, handing sign-in to the handler if Amazon asks for it —
  /// at the start, and on every stall recovery, which is where a session that
  /// expired mid-book turns up.
  private func openReader(timeout: TimeInterval) async throws {
    try await session.load(bookReaderURL, timeout: timeout)
    // A session with no cookies is sent on to the landing page by a script
    // after the load has finished, so the URL right now proves nothing yet:
    // wait for the reader or a signed-out page, whichever comes first.
    _ = try await session.waitFor(timeout: timeout, interval: 0.2) {
      if self.session.isOnSignIn { return true }
      return await self.session.exists(ElementSpec(Self.mainImageSelector, visible: false))
    }
    if session.isOnSignIn {
      try await handleSignIn()
      if session.currentURL?.absoluteString.contains(bookReaderURL.absoluteString) != true {
        try await session.load(bookReaderURL, timeout: timeout)
      }
    }
  }

  private func handleSignIn() async throws {
    info("Amazon needs you to sign in. Complete sign-in in the reader window...")
    onEvent?(.needsSignIn)
    guard let signInHandler else { throw CaptureError.needsSignIn }
    // The handler shows whatever page is there; on the landing page that
    // would leave the person to find its sign-in button themselves.
    await session.leaveLandingPage()
    do {
      try await signInHandler(session)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CaptureError.needsSignIn
    }
    info("Signed in.")
  }

  /// Build meta/info/toc/locationMap/nav from what the reader downloaded.
  private func buildMetadata() async throws {
    // The render TARs normally arrived with the first page; give a slow one a
    // moment rather than failing on a race.
    _ = try await session.waitFor(timeout: 10, interval: 0.2) {
      self.session.renders.contains { $0.locationMap != nil }
    }
    if session.yjMetadataText == nil, session.startReadingJSON != nil {
      await session.fetchYJMetadataFallback()
    }

    let args = BuildMetadataInput(
      asin: options.asin, renders: session.renders,
      yjMetadata: session.yjMetadataText.flatMap { ReaderSession.parseJSONP($0) }.flatMap {
        try? RawJSON(JSONSerialization.data(withJSONObject: $0))
      },
      startReading: session.startReadingJSON.flatMap { text -> RawJSON? in
        let data = Data(text.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) == nil ? nil : RawJSON(data)
      })
    let built = try core.callJSON("buildBookMetadata", args)

    document = MetadataDocument()
    try document.merge(json: built)
    try document.setCaptureId(UUID().uuidString.lowercased())
    try document.set("pages", json: "[]")
    pages = []
    guard let navData = try document.json("nav"), let locationMapData = try document.json("locationMap")
    else { throw CaptureError.failed("book metadata is missing nav or locationMap") }
    nav = try JSONDecoder().decode(BookNav.self, from: navData)
    locationMap = RawJSON(locationMapData)
  }

  private func writeMetadata() throws {
    if let capture { try document.setCapture(capture) }
    try document.write(to: metadataURL)
  }

  /// Load the reader afresh and put it back on `pageNumber`. The hooks are
  /// user scripts, so they come back with the document; only what the first
  /// load did to the document itself has to be redone.
  private func reloadReader(at pageNumber: Int) async throws {
    // Object URLs die with their document.
    session.blobs.removeAll()
    try await openReader(timeout: 60)
    guard try await session.waitFor(ElementSpec(Self.mainImageSelector, visible: false), timeout: 60)
    else { throw CaptureError.failed("the reader did not show a page after reloading") }
    _ = await dismissPossibleAlert()
    await ensureFixedHeaderUI()
    // Screens are only recognised as already captured if they render
    // identically, so the font and layout are re-applied.
    try await updateSettings()
    try await goToPage(pageNumber)
  }

  /// Reload and carry on if the stop is a stall worth recovering from,
  /// otherwise record it as the end. Returns whether to carry on. Every
  /// attempt is written to the metadata before it's made.
  private func recoverOrStop(_ stop: CaptureStop) async throws -> Bool {
    guard var state = capture else { return false }
    while true {
      let decision = try core.call(
        "shouldRecover",
        RecoveryInput(reason: stop.reason, page: state.lastPage, recoveries: state.recoveries ?? []),
        as: RecoveryDecision.self)

      if decision.type == "give-up" {
        switch decision.why {
        case "recovery-limit":
          info("not reloading the reader again: it has already been reloaded as often as allowed")
        case "stuck-here":
          info("not reloading the reader again: it has stalled at page \(state.lastPage) after reloading")
        default: break
        }
        state.complete = stop.complete
        state.reason = stop.reason
        capture = state
        return false
      }

      var recoveries = state.recoveries ?? []
      recoveries.append(CaptureRecovery(reason: stop.reason, page: state.lastPage, screens: pages.count))
      state.recoveries = recoveries
      capture = state
      try writeMetadata()

      let resumePage = state.lastPage > 0 ? state.lastPage : (nav?.startContentPage ?? 1)
      info(
        "the reader stopped responding (\(stop.reason)) after page \(state.lastPage); "
          + "reloading it and resuming from page \(resumePage) (recovery \(recoveries.count))...")

      do {
        try await reloadReader(at: resumePage)
        resume = ResumeState(page: resumePage, skipped: 0)
        return true
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Counted all the same, so a reader that can't be reloaded runs out
        // of attempts instead of looping.
        info("reloading the reader failed: \(error)")
      }
    }
  }

  // MARK: - reader UI

  private func ensureFixedHeaderUI() async {
    _ = await session.run(ReaderScripts.fixHeader, as: Bool.self)
  }

  /// Answer the "Most Recent Page Read" dialog (always No: we start from the
  /// beginning), or any other yes/no alert in the way.
  @discardableResult
  func dismissPossibleAlert() async -> Bool {
    guard
      let target = await session.run(
        ReaderScripts.alertNoButton, as: ReaderSession.ElementCenter.self)
    else { return false }
    if target.kind == "most-recent-page-read" {
      info("dismissing \"Most Recent Page Read\" dialog")
    }
    session.click(css: CGPoint(x: target.x, y: target.y))
    try? await sleep(0.3)
    return true
  }

  /// Close a reader popover that got stuck open, least disruptive way first.
  private func dismissReaderPopoverMenu() async throws {
    let popover = ElementSpec("ion-popover")
    guard await session.exists(popover) else { return }
    session.press(.escape)
    try await sleep(0.15)
    session.click(css: CGPoint(x: 10, y: 10))
    try await sleep(0.15)
    if await session.exists(popover) {
      if let backdrop = await session.center(of: ElementSpec("ion-backdrop", visible: false)) {
        session.click(css: CGPoint(x: backdrop.x, y: backdrop.y))
      }
      try await sleep(0.15)
    }
  }

  /// Amazon Ember font, single column — by real clicks.
  private func updateSettings() async throws {
    try await dismissReaderPopoverMenu()
    info("Looking for Reader settings button")
    guard try await session.click(Self.settingsButton, timeout: 30) else {
      throw CaptureError.failed("Reader settings button not found")
    }
    try await sleep(0.5)

    info("Changing font to Amazon Ember")
    guard try await session.click(ElementSpec("#AmazonEmber"), timeout: 30) else {
      throw CaptureError.failed("Amazon Ember font option not found")
    }
    try await sleep(0.2)

    info("Changing to single column layout")
    let singleColumn = ElementSpec(
      "*", text: "Single Column", flags: "i",
      within: ElementSpec(#"[role="radiogroup"][aria-label$=" columns"]"#), deepest: true)
    guard try await session.click(singleColumn, timeout: 30) else {
      throw CaptureError.failed("single column layout option not found")
    }
    try await sleep(0.2)

    info("Closing settings")
    // The sync dialog can surface while the panel is open and swallow this click.
    _ = await dismissPossibleAlert()
    _ = try await session.click(Self.settingsButton, timeout: 10)
    try await sleep(0.5)
    try await dismissReaderPopoverMenu()
  }

  // MARK: - position

  private func footerPageNav() async -> PageNav? {
    let text = await session.textContent(Self.footerSelector)
    return (try? core.call("parsePageNav", text, as: PageNav?.self)) ?? nil
  }

  /// The footer nav, tolerating the moment after a page turn or a modal
  /// close where it hasn't re-rendered yet.
  func readPageNav() async -> PageNav? {
    for _ in 0..<10 {
      if let nav = await footerPageNav() { return nav }
      try? await sleep(0.2)
    }
    return nil
  }

  /// Open the reader menu and choose "Go to Page" / "Go to Location".
  private func openGoToModal() async throws -> Bool {
    _ = await dismissPossibleAlert()
    try await dismissReaderPopoverMenu()
    await session.hover(ElementSpec("#reader-header", visible: false))
    try await sleep(0.2)
    guard try await session.click(ElementSpec(#"ion-button[aria-label="Reader menu"]"#), timeout: 10)
    else { return false }

    let goToPage = ElementSpec.hasText(#"ion-item[role="listitem"]"#, "Go to Page")
    let goToLocation = ElementSpec.hasText(#"ion-item[role="listitem"]"#, "Go to Location")
    _ = try await session.waitFor(timeout: 5) {
      let page = await self.session.exists(goToPage)
      if page { return true }
      return await self.session.exists(goToLocation)
    }

    if try await session.click(goToPage, timeout: 0) { return true }
    if try await session.click(goToLocation, timeout: 0) { return true }
    try await dismissReaderPopoverMenu()
    return false
  }

  func goToPage(_ pageNumber: Int) async throws {
    var opened = false
    for _ in 0..<3 where !opened {
      opened = try await openGoToModal()
    }
    guard opened else {
      throw CaptureError.failed("Unable to find \"Go to Page\" or \"Go to Location\" menu item")
    }

    let digits = String(pageNumber)
    if try await session.waitFor(Self.goToModalInput, timeout: 5) {
      _ = try await session.click(Self.goToModalInput, timeout: 1)
      _ = await session.run(
        ReaderScripts.focusAndSelect, ["spec": ReaderSession.specArgument(Self.goToModalInput)],
        as: Bool.self)
      try await session.type(digits)
      let value = await session.run(
        ReaderScripts.inputValue, ["spec": ReaderSession.specArgument(Self.goToModalInput)],
        as: String?.self) ?? nil
      if value != digits {
        _ = await session.run(
          ReaderScripts.setInputValue,
          ["spec": ReaderSession.specArgument(Self.goToModalInput), "value": digits], as: Bool.self)
      }
    }

    if !(try await session.click(Self.goToModalGoButton, timeout: 2)) {
      session.press(.enter)
    }
    try await sleep(1)
    try await dismissReaderPopoverMenu()
    // So arrow keys turn pages rather than move a caret in a leftover field.
    _ = await session.run(ReaderScripts.blurTextField, as: Bool.self)

    let arrived = await readPageNav()
    if arrived?.page != pageNumber {
      info(
        "Go to page \(pageNumber) failed; footer reports \(arrived.map(Self.describe) ?? "nothing"); walking...")
      try await dismissGoToModal()
      try await walkToPage(pageNumber)
    }
  }

  private func dismissGoToModal() async throws {
    let modal = ElementSpec("ion-modal.go-to-modal.show-modal")
    guard await session.exists(modal) else { return }
    let cancel = ElementSpec(
      #"ion-button[item-i-d="go-to-modal-cancel-button"]"#, within: modal)
    if !(try await session.click(cancel, timeout: 1)) {
      session.press(.escape)
    }
    try await sleep(0.3)
  }

  private func walkToPage(_ pageNumber: Int) async throws {
    var previousPage: Int?
    var stuck = 0

    for _ in 0..<500 {
      try Task.checkCancellation()
      guard let pageNav = await readPageNav() else {
        let footer = await session.textContent(Self.footerSelector)
        throw CaptureError.failed(
          "Unable to read current page while walking to \(pageNumber) (footer reads: \(footer ?? "null"))")
      }

      // The footer reports a location in front/back matter and for roman
      // numerals; derive a page from it so the walk knows which way to go.
      var currentPage = pageNav.page
      if currentPage == nil, let location = pageNav.location {
        currentPage = try core.call("pageForPosition", locationMap, location, as: Int.self)
      }

      if currentPage == pageNumber { return }
      if pageNumber == 1, let currentPage, currentPage <= 1 { return }

      // Without a page to compare, assume we're ahead of the content.
      let backwards = currentPage.map { $0 > pageNumber } ?? false
      let chevron = backwards ? Self.previousChevronSelector : Self.nextChevronSelector

      // A walk that stops moving has hit something; if the chevron in our
      // direction is gone (twice), that's the edge of the book.
      if let currentPage, currentPage == previousPage {
        stuck += 1
        let chevronMissing = (await session.count(chevron) ?? 1) == 0
        if chevronMissing, stuck >= 2 {
          info(
            "stopping walk at page \(currentPage): no \(backwards ? "left" : "right") chevron, "
              + "so page \(pageNumber) is past the edge of the book")
          return
        }
        if stuck >= 5 {
          throw CaptureError.failed("Unable to walk to page \(pageNumber); stuck at page \(currentPage)")
        }
        // The input that didn't move it: try the other one.
        preferredTurn = preferredTurn == .key ? .mouse : .key
      } else {
        stuck = 0
      }
      previousPage = currentPage

      let src = await session.imageSource(Self.mainImageSelector)
      await turn(backwards: backwards, chevron: chevron)

      _ = try await session.waitFor(timeout: 5, interval: 0.05) {
        if let next = await self.footerPageNav(), let page = next.page, page != pageNav.page {
          return true
        }
        let newSrc = await self.session.imageSource(Self.mainImageSelector)
        return src != nil && newSrc != nil && newSrc != src
      }
    }

    let last = await footerPageNav()
    throw CaptureError.failed(
      "Unable to walk to page \(pageNumber); last page was \(last?.page.map(String.init) ?? "unknown")")
  }

  // MARK: - page turning

  /// One page turn with the preferred input: an arrow key, or a real click
  /// on the chevron. Never both in one attempt — a slow turn plus a second
  /// input would skip a screen silently.
  private func turn(backwards: Bool, chevron: String) async {
    switch preferredTurn {
    case .key:
      session.press(backwards ? .arrowLeft : .arrowRight)
    case .mouse:
      if !((try? await session.click(ElementSpec(chevron), timeout: 1)) ?? false) {
        session.press(backwards ? .arrowLeft : .arrowRight)
      }
    }
  }

  /// The capture loop's "click the next-page chevron": wait (up to
  /// `chevronTimeout`) for a visible chevron, then turn. Returns false — the
  /// TS `clickFailed` — when there was no chevron to turn with, which is the
  /// usual state of the final screen.
  private func turnPage(from _: String, chevronTimeout: TimeInterval, quiet: Bool) async throws
    -> Bool
  {
    let chevron = ElementSpec(Self.nextChevronSelector)
    guard try await session.waitFor(chevron, timeout: chevronTimeout) else {
      if !quiet { info("unable to find the next page button") }
      return false
    }
    await turn(backwards: false, chevron: Self.nextChevronSelector)
    return true
  }

  /// Whether the main image's `src` changed within `timeout` — the most
  /// reliable sign Kindle moved to another rendered page.
  private func waitForSourceChange(from src: String, timeout: TimeInterval) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try Task.checkCancellation()
      if let newSrc = await session.imageSource(Self.mainImageSelector), newSrc != src {
        return true
      }
      try await sleep(0.01)
    }
    return false
  }

  /// The captured blob for `src`, waiting up to 10 s for it to arrive.
  private func takeBlob(_ src: String) async throws -> BlobStore.Blob? {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let blob = session.blobs.take(src) { return blob }
      try await sleep(0.005)
    }
    return session.blobs.take(src)
  }

  private func sleep(_ seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
  }
}

// MARK: - KindleCore argument shapes

struct BeforeCaptureInput: Encodable {
  var hasPageNav: Bool
  var currentPage: Int
  var totalContentPages: Int
}

struct FooterPosition: Encodable {
  var value: Int?
  var total: Int
}

struct NavigationTimeoutInput: Encodable {
  var onLastNumberedPage: Bool
  var clickFailed: Bool
}

/// `NavigationEvidence`.
struct NavigationEvidence: Encodable {
  var navigated: Bool
  var signedOut: Bool
  var pageImage: Bool
  var footerReadable: Bool
  var nextPageUsable: Bool
}

struct StopCaptureInput: Encodable {
  var observations: [NavigationResult]
  var onLastNumberedPage: Bool
  var maxAttempts: Int
}

struct RecoveryInput: Encodable {
  var reason: String
  var page: Int
  var recoveries: [CaptureRecovery]
}

struct ResumeScreenInput: Encodable {
  var resume: ResumeState
  var alreadyCaptured: Bool
  var currentPage: Int
  var capturedAny: Bool
}

struct BuildMetadataInput: Encodable {
  var asin: String
  var renders: [RenderFiles]
  var yjMetadata: RawJSON?
  var startReading: RawJSON?
}
