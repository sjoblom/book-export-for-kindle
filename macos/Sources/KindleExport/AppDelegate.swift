import AppKit
import Foundation
import KindleExportKit
import WebKit

/// Windows, menus and the app's lifecycle. The behaviour lives in
/// `AppModel`; this is the shell around it (patterns from the Node-based
/// launcher, native/launcher/main.swift).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate,
  WKUIDelegate
{
  private var environment = AppEnvironment.standard()
  private var backend: NativeBackend!
  private var model: AppModel!
  private var bridge: Bridge!
  private var window: NSWindow!
  /// The library UI (the page). Stays loaded, hidden, while sign-in shows.
  private var webView: WKWebView!
  /// Amazon's sign-in with the app's bar above it, in place of the page.
  private var signInView: SignInView!
  /// The page currently shown, when it is the real UI (not an error page).
  private var pageURL: URL?
  private let commandLineTool = CommandLineToolMenu()

  func applicationDidFinishLaunching(_: Notification) {
    try? FileManager.default.createDirectory(
      at: environment.outDir, withIntermediateDirectories: true)

    backend = NativeBackend(outDir: environment.outDir)
    model = AppModel(backend: backend, environment: environment)
    bridge = Bridge(model: model)
    model.onStateChange = { [weak self] json in self?.bridge.pushState(json) }

    buildMenu()
    buildWindow()
    loadPage()

    backend.onPlacementChange = { [weak self] placement in self?.placeReader(placement) }

    Task { @MainActor in await self.model.start() }
    Autotest.startIfAsked(model: model, backend: backend, environment: environment)
  }

  // MARK: - window

  private func buildWindow() {
    let configuration = WKWebViewConfiguration()
    bridge.install(on: configuration)

    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    // Web Inspector on demand: `KINDLE_EXPORT_INSPECT=1 open -a "Kindle Export"`.
    if #available(macOS 13.3, *),
      ProcessInfo.processInfo.environment["KINDLE_EXPORT_INSPECT"] == "1"
    {
      webView.isInspectable = true
    }
    bridge.attach(webView)

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Kindle Export"
    window.minSize = NSSize(width: 520, height: 480)

    // One window, two faces: the page, or Amazon's sign-in. Both fill it;
    // only one is visible at a time.
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 760))
    signInView = SignInView(frame: content.bounds)
    signInView.isHidden = true
    signInView.onCancel = { [weak self] in self?.backend.cancelSignIn() }
    for view in [webView!, signInView!] as [NSView] {
      view.frame = content.bounds
      view.autoresizingMask = [.width, .height]
      content.addSubview(view)
    }
    window.contentView = content
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    // Remembers where the person left it, across launches.
    window.setFrameAutosaveName("KindleExportMainWindow")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// The UI page from the bundle (or the checkout, for `swift run`), loaded as
  /// a file so its origin is the file itself; covers load from Amazon's
  /// image hosts over https, which a file page may do.
  private func loadPage() {
    guard let url = AppPage.locate() else {
      pageURL = nil
      webView.loadHTMLString(Self.missingPage(), baseURL: nil)
      return
    }
    pageURL = url
    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }

  static func missingPage() -> String {
    let looked = AppPage.candidates().map { "<li><code>\(escapeHTML($0.path))</code></li>" }
      .joined()
    return """
      <!doctype html><html><head><meta charset="utf-8"><style>
      :root { color-scheme: light dark; }
      body { font: 15px -apple-system, sans-serif; max-width: 640px; margin: 15vh auto; padding: 0 24px; }
      code { font-size: 12px; }
      </style></head><body>
      <h2>Kindle Export can't show its window</h2>
      <p>The page it displays (<code>app.html</code>) is missing from the app.
      Reinstalling Kindle Export should fix this.</p>
      <p>For developers: run <code>pnpm build:app-page</code>, then View › Reload.
      Looked in:</p><ul>\(looked)</ul>
      </body></html>
      """
  }

  static func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  /// Swap what the window shows. The reader's web view is the same one the
  /// whole time — moved between the invisible host window and this one — so
  /// its session and page carry on; the page stays loaded underneath.
  private func placeReader(_ placement: NativeBackend.ReaderPlacement) {
    let session = backend.session
    switch placement {
    case .signIn:
      // Move the (already loaded) reader into the laid-out sign-in view, then
      // fade that in over the page. The page stays where it is underneath,
      // never hidden, so neither direction shows a blank frame, and the
      // window keeps its size and place.
      signInView.alphaValue = 0
      signInView.isHidden = false
      signInView.layoutSubtreeIfNeeded()
      session.present(in: signInView.readerSlot)
      showWindow()
      window.makeFirstResponder(session.webView)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        signInView.animator().alphaValue = 1
      }

    case .background:
      // Straight back to the page, which stayed loaded (and up to date)
      // underneath; the reader goes back to its host before any background
      // work drives it again.
      signInView.isHidden = true
      signInView.alphaValue = 1
      session.hostInBackground()
      window.makeFirstResponder(webView)
    }
  }

  /// Closing the main window is quitting (which asks first mid-export).
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === window else { return true }
    NSApp.terminate(nil)
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

  /// Reopening from the Dock brings the main window back.
  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    showWindow()
    return true
  }

  @objc private func showWindow() {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func reloadPage() {
    // A page that was missing may have been built since.
    if pageURL == nil || webView.url == nil || webView.url?.isFileURL != true {
      loadPage()
    } else {
      webView.reload()
    }
  }

  @objc private func showBooks() {
    try? FileManager.default.createDirectory(
      at: environment.outDir, withIntermediateDirectories: true)
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: environment.outDir.path)
  }

  // MARK: - quitting

  /// Quitting mid-export throws away the book in progress — up to an hour of
  /// capture — so ask first.
  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    guard model?.busy == .export else { return .terminateNow }

    let alert = NSAlert()
    alert.messageText = "A book is still being exported"
    alert.informativeText =
      "Quitting now stops it. Books already finished are kept, and the "
      + "one in progress can be started again later."
    alert.addButton(withTitle: "Keep Working")
    alert.addButton(withTitle: "Quit Anyway")
    showWindow()
    alert.beginSheetModal(for: window) { response in
      NSApp.reply(toApplicationShouldTerminate: response == .alertSecondButtonReturn)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_: Notification) {
    model?.dispose()
  }

  // MARK: - navigation

  /// The app's own page loads in the window; any other link — a website —
  /// opens in the person's browser, where it belongs.
  func webView(
    _: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }

    if url.scheme == "about" || url.scheme == "data" {
      return decisionHandler(.allow)
    }
    if url.isFileURL {
      // Only the page itself (reloads, in-page anchors); no other files.
      let same = pageURL.map { $0.standardizedFileURL.path == url.standardizedFileURL.path } ?? false
      return decisionHandler(same ? .allow : .cancel)
    }

    decisionHandler(.cancel)
    if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
    }
  }

  /// `target="_blank"` links get the same treatment instead of doing nothing.
  func webView(
    _: WKWebView, createWebViewWith _: WKWebViewConfiguration, for action: WKNavigationAction,
    windowFeatures _: WKWindowFeatures
  ) -> WKWebView? {
    if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
    }
    return nil
  }

  func webView(
    _: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame _: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window) { _ in completionHandler() }
  }

  func webView(
    _: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame _: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  /// A crashed web content process would otherwise leave a blank window.
  func webViewWebContentProcessDidTerminate(_: WKWebView) {
    loadPage()
  }

  // MARK: - menu

  private func buildMenu() {
    let mainMenu = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Show Books in Finder", action: #selector(showBooks), keyEquivalent: "b"
    ).target = self
    appMenu.addItem(NSMenuItem.separator())
    commandLineTool.addItems(to: appMenu)
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: "Hide Kindle Export", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(
      withTitle: "Quit Kindle Export", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    addSubmenu(appMenu, to: mainMenu)

    // Without an Edit menu, ⌘C/⌘V/⌘A do nothing in a web view's text fields —
    // pasting a password into Amazon's sign-in would silently fail.
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    addSubmenu(editMenu, to: mainMenu)

    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r").target =
      self
    addSubmenu(viewMenu, to: mainMenu)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Kindle Export", action: #selector(showWindow), keyEquivalent: "0"
    ).target = self
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    addSubmenu(windowMenu, to: mainMenu)
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }

  private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
    let item = NSMenuItem()
    item.submenu = submenu
    menu.addItem(item)
  }
}
