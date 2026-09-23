import AppKit
import WebKit
import XCTest

@testable import KindleExportKit

/// One visible window: the reader's web view lives in an invisible host
/// window, and is lent to the main window only while Amazon's sign-in has to
/// be seen.
@MainActor
final class ReaderHostingTests: XCTestCase {
  func testTheHostWindowIsInvisibleToThePerson() throws {
    let session = ReaderSession()
    session.hostInBackground()
    defer { session.hostWindow.orderOut(nil) }

    let host = try XCTUnwrap(session.hostWindow as? ReaderHostWindow)
    XCTAssertTrue(session.window === host)
    XCTAssertTrue(host.styleMask == [.borderless])
    XCTAssertTrue(host.isExcludedFromWindowsMenu)
    XCTAssertTrue(host.collectionBehavior.contains(.transient))
    XCTAssertTrue(host.collectionBehavior.contains(.ignoresCycle))
    XCTAssertFalse(host.canBecomeKey)
    XCTAssertFalse(host.canBecomeMain)
    XCTAssertTrue(host.ignoresMouseEvents)
    // Ordered in (WebKit renders it, events reach it) but on no screen, and
    // not minimized — so not in the Dock either.
    XCTAssertTrue(host.isVisible)
    XCTAssertFalse(host.isMiniaturized)
    // This WebKit lets occlusion detection be switched off, so the window
    // can sit wholly off-screen (the verified configuration).
    XCTAssertEqual(host.mode, .offscreen)
    XCTAssertFalse(host.isOnAnyScreen)
    XCTAssertEqual(host.alphaValue, 1)
    XCTAssertEqual(session.webView.frame.size, ReaderSession.viewportSize)
  }

  func testTheSliverFallbackIsInvisibleToo() {
    let host = ReaderHostWindow(size: ReaderSession.viewportSize)
    host.mode = .sliver
    host.orderInOffscreen()
    defer { host.orderOut(nil) }
    XCTAssertTrue(host.isVisible)
    XCTAssertLessThanOrEqual(host.alphaValue, 0.011)
    XCTAssertLessThan(host.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)))
    // One point of it overlaps a screen — enough for WindowServer to call it
    // visible — and no more.
    if let screen = NSScreen.screens.first?.frame {
      let overlap = screen.intersection(host.frame)
      XCTAssertLessThanOrEqual(overlap.width * overlap.height, 1)
    }
  }

  func testTheOffscreenOriginClearsEveryScreen() {
    let screens = [
      NSRect(x: 0, y: 0, width: 1728, height: 1117),
      NSRect(x: -2560, y: 200, width: 2560, height: 1440),
      NSRect(x: 1728, y: -900, width: 1080, height: 1920),
    ]
    let size = ReaderSession.viewportSize
    let origin = ReaderHostWindow.offscreenOrigin(for: size, screens: screens)
    let frame = NSRect(origin: origin, size: size)
    for screen in screens { XCTAssertFalse(screen.intersects(frame)) }
  }

  func testLendingTheReaderKeepsTheSameWebView() {
    let session = ReaderSession()
    session.hostInBackground()
    let webView = session.webView
    let main = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    let slot = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
    main.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    main.contentView!.addSubview(slot)
    defer {
      session.hostWindow.orderOut(nil)
      main.orderOut(nil)
    }

    session.present(in: slot)
    XCTAssertTrue(session.webView === webView)
    XCTAssertTrue(webView.superview === slot)
    XCTAssertTrue(session.isPresented)
    // Synthesized events follow the web view to whichever window has it.
    XCTAssertTrue(session.window === main)
    XCTAssertEqual(webView.frame, slot.bounds)

    session.returnToHost()
    XCTAssertTrue(session.webView === webView)
    XCTAssertFalse(session.isPresented)
    XCTAssertTrue(session.window === session.hostWindow)
    // Back at the capture's viewport, whatever size the main window had.
    XCTAssertEqual(webView.frame.size, ReaderSession.viewportSize)
  }

  // MARK: - sign-in placement

  func makeBackend() throws -> NativeBackend {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reader-hosting-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let backend = NativeBackend(outDir: dir)
    addTeardownBlock { @MainActor in backend.session.hostWindow.orderOut(nil) }
    return backend
  }

  func testSignInShowsTheReaderAndCancelPutsItBack() async throws {
    let backend = try makeBackend()
    backend.isSignedIn = { _ in false }
    var placements: [NativeBackend.ReaderPlacement] = []
    backend.onPlacementChange = { placements.append($0) }

    let wait = Task { await backend.waitForSignIn() }
    try await waitUntil { backend.placement == .signIn }
    XCTAssertTrue(backend.signingIn)

    backend.cancelSignIn()
    let confirmed = await wait.value
    XCTAssertFalse(confirmed)
    XCTAssertEqual(placements, [.signIn, .background])
    XCTAssertEqual(backend.placement, .background)
    XCTAssertFalse(backend.signingIn)
    XCTAssertFalse(backend.session.isPresented)
  }

  func testSignInEndsByItselfOnceAmazonSettlesOnTheReader() async throws {
    let backend = try makeBackend()
    var signedIn = false
    var checks = 0
    backend.isSignedIn = { _ in
      checks += 1
      return signedIn
    }
    var placements: [NativeBackend.ReaderPlacement] = []
    backend.onPlacementChange = { placements.append($0) }

    let wait = Task { await backend.waitForSignIn() }
    try await waitUntil { backend.placement == .signIn }
    signedIn = true
    let confirmed = await wait.value
    XCTAssertTrue(confirmed)
    XCTAssertEqual(placements, [.signIn, .background])
    // One signed-in look is not enough: Amazon may still be on its way back
    // to sign-in.
    XCTAssertGreaterThanOrEqual(checks, NativeBackend.signedInPollsNeeded)
  }

  func testWithoutAShellTheReaderStaysInItsHost() async throws {
    let backend = try makeBackend()
    backend.isSignedIn = { _ in false }
    let wait = Task { await backend.waitForSignIn() }
    try await waitUntil { backend.placement == .signIn }
    backend.cancelSignIn()
    _ = await wait.value
    XCTAssertFalse(backend.session.isPresented)
    XCTAssertTrue(backend.session.hostWindow.isVisible)
  }

  func testTheSignInBarSaysWhatIsGoingOn() {
    let view = SignInView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    XCTAssertEqual(view.titleLabel.stringValue, "Sign in to Amazon to see your books")
    XCTAssertEqual(
      view.detailLabel.stringValue,
      "This is Amazon’s own page — Kindle Export never sees your password.")
    XCTAssertEqual(view.cancelButton.title, "Cancel")
    var cancelled = false
    view.onCancel = { cancelled = true }
    view.cancelButton.performClick(nil)
    XCTAssertTrue(cancelled)

    view.layoutSubtreeIfNeeded()
    // The reader gets everything below the bar.
    XCTAssertEqual(view.readerSlot.frame.width, 900)
    XCTAssertEqual(view.readerSlot.frame.height, 700 - SignInView.barHeight - 1, accuracy: 0.5)
  }

  func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline {
        XCTFail("timed out")
        throw CancellationError()
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}
