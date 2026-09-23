import AppKit
import Foundation
import WebKit

// The double-clickable front end. It starts the local server, waits for it to
// answer, and shows the web app in a window of its own — not a browser tab,
// which is one of many, easy to close by accident, and outlives the server
// behind it. The window, the Dock icon and Quit all belong to one app, and
// quitting takes the server with it: a stray server keeps the port and the
// next launch fails, which is precisely the failure someone non-technical
// cannot diagnose.
//
// Amazon sign-in and page capture still happen in a separate Chrome window.
// That one is driven by Playwright and cannot live inside a web view.

let port = 8484
let serverURL = URL(string: "http://127.0.0.1:\(port)")!

/// Books land somewhere predictable rather than wherever the OS set the working
/// directory, which for a double-clicked app is `/`.
let outDir = FileManager.default
  .homeDirectoryForCurrentUser
  .appendingPathComponent("Documents/Kindle Export")

let logURL = FileManager.default
  .homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Logs/Kindle Export.log")

func resource(_ relativePath: String) -> URL {
  Bundle.main.bundleURL
    .appendingPathComponent("Contents/Resources")
    .appendingPathComponent(relativePath)
}

/// Whether something is already listening, i.e. a server is up.
func serverIsUp() -> Bool {
  guard let socket = try? Socket(port: UInt16(port)) else { return false }
  defer { socket.close() }
  return socket.connectSucceeds()
}

/// Minimal blocking TCP connect; enough to answer "is the port open?".
final class Socket {
  private let fd: Int32
  private let port: UInt16

  init(port: UInt16) throws {
    self.port = port
    fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { throw POSIXError(.EBADF) }
  }

  func connectSucceeds() -> Bool {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
  }

  func close() { Darwin.close(fd) }
}

func showFatalError(_ message: String) {
  let alert = NSAlert()
  alert.messageText = "Kindle Export could not start"
  alert.informativeText = "\(message)\n\nDetails are in:\n\(logURL.path)"
  alert.alertStyle = .critical
  alert.addButton(withTitle: "OK")
  alert.runModal()
}

/// Shown while Node starts, so the window appears at once instead of after a
/// pause that looks like the app failed to open.
let startingPage = """
  <!doctype html><html><head><meta charset="utf-8"><style>
  :root { color-scheme: light dark; }
  body { font: 15px -apple-system, sans-serif; display: grid; place-items: center;
         height: 100vh; margin: 0; color: #888; }
  </style></head><body>Starting Kindle Export…</body></html>
  """

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  WKNavigationDelegate, WKUIDelegate
{
  private var server: Process?
  private var window: NSWindow!
  private var webView: WKWebView!

  func applicationDidFinishLaunching(_: Notification) {
    buildMenu()
    buildWindow()

    // A server already on the port — a second copy of the app, or
    // `kindle-export serve` from a terminal — is shown rather than fought for
    // the port.
    if serverIsUp() {
      webView.load(URLRequest(url: serverURL))
      return
    }

    do {
      try startServer()
    } catch {
      showFatalError(error.localizedDescription)
      NSApp.terminate(nil)
      return
    }

    waitForServerThenLoad()
  }

  // ----------------------------------------------------------------- window

  private func buildWindow() {
    webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    // Web Inspector on demand, for debugging the packaged app itself:
    // `KINDLE_EXPORT_INSPECT=1 open -a "Kindle Export"`.
    if #available(macOS 13.3, *),
      ProcessInfo.processInfo.environment["KINDLE_EXPORT_INSPECT"] == "1"
    {
      webView.isInspectable = true
    }
    webView.loadHTMLString(startingPage, baseURL: nil)

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Kindle Export"
    window.minSize = NSSize(width: 520, height: 480)
    window.contentView = webView
    window.delegate = self
    window.center()
    // Remembers where the user left it, across launches.
    window.setFrameAutosaveName("KindleExportMainWindow")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// One window, and it is the app: closing it quits, which stops the server.
  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
    true
  }

  /// Reopening from the Dock brings the window back.
  func applicationShouldHandleReopen(
    _: NSApplication, hasVisibleWindows _: Bool
  ) -> Bool {
    showWindow()
    return true
  }

  @objc private func showWindow() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func reloadPage() {
    if webView.url?.host == serverURL.host {
      webView.reload()
    } else if serverIsUp() {
      webView.load(URLRequest(url: serverURL))
    }
  }

  // ------------------------------------------------------------ navigation

  /// The app's own pages load in the window. Download links are saved to
  /// Downloads here rather than handed to WebKit, whose download support needs
  /// a newer macOS than this app targets. Anything else — a link to a website
  /// — opens in the user's browser, where it belongs.
  func webView(
    _: WKWebView,
    decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }

    if url.scheme == "about" || url.scheme == "data" {
      return decisionHandler(.allow)
    }

    if isAppURL(url) {
      if url.path.hasPrefix("/api/download/") {
        decisionHandler(.cancel)
        download(url)
        return
      }
      return decisionHandler(.allow)
    }

    decisionHandler(.cancel)
    NSWorkspace.shared.open(url)
  }

  /// Links that ask for a new window (`target="_blank"`) get the same
  /// treatment as any other link instead of silently doing nothing.
  func webView(
    _ webView: WKWebView,
    createWebViewWith _: WKWebViewConfiguration,
    for action: WKNavigationAction,
    windowFeatures _: WKWindowFeatures
  ) -> WKWebView? {
    if let url = action.request.url {
      if isAppURL(url), url.path.hasPrefix("/api/download/") {
        download(url)
      } else if isAppURL(url) {
        webView.load(URLRequest(url: url))
      } else {
        NSWorkspace.shared.open(url)
      }
    }
    return nil
  }

  func webView(
    _: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame _: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window) { _ in completionHandler() }
  }

  func webView(
    _: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame _: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  /// The server answers to `localhost` and `127.0.0.1` alike.
  private func isAppURL(_ url: URL) -> Bool {
    (url.host == "127.0.0.1" || url.host == "localhost") && url.port == port
  }

  // -------------------------------------------------------------- downloads

  private func download(_ url: URL) {
    URLSession.shared.downloadTask(with: url) { temp, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard let temp, error == nil, status == 200 else {
        DispatchQueue.main.async {
          self.showError(
            "The file could not be downloaded.",
            detail: error?.localizedDescription ?? "The server answered \(status)."
          )
        }
        return
      }

      // The last path segment is the file's real name; the server has
      // already refused anything that isn't a plain file name.
      let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
      do {
        let target = try self.moveIntoDownloads(temp, name: name)
        DispatchQueue.main.async {
          NSWorkspace.shared.activateFileViewerSelecting([target])
        }
      } catch {
        DispatchQueue.main.async {
          self.showError("The file could not be saved.", detail: error.localizedDescription)
        }
      }
    }.resume()
  }

  /// Move a finished download into ~/Downloads without overwriting anything:
  /// a second download of the same book becomes `name 2.md`, as Safari does.
  private func moveIntoDownloads(_ temp: URL, name: String) throws -> URL {
    let fm = FileManager.default
    let downloads = try fm.url(
      for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var target = downloads.appendingPathComponent(name)
    var n = 2
    while fm.fileExists(atPath: target.path) {
      target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
      n += 1
    }

    try fm.moveItem(at: temp, to: target)
    return target
  }

  private func showError(_ message: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window)
  }

  // ----------------------------------------------------------------- server

  private func startServer() throws {
    try FileManager.default.createDirectory(
      at: outDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let node = resource("node/bin/node")
    let entry = resource("app/dist/cli.js")

    for required in [node, entry] where !FileManager.default.fileExists(atPath: required.path) {
      throw NSError(
        domain: "KindleExport", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The app bundle is incomplete — \(required.lastPathComponent) is missing."
        ])
    }

    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    log.seekToEndOfFile()

    let process = Process()
    process.executableURL = node
    process.arguments = [
      entry.path, "serve",
      "--port", String(port),
      // Explicit, because the working directory of a double-clicked app is not
      // anywhere the user would think to look.
      "--out-dir", outDir.path,
    ]
    process.currentDirectoryURL = outDir
    process.standardOutput = log
    process.standardError = log
    // The server opens a browser tab itself when run from a terminal; here the
    // page belongs in this app's window instead.
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["KINDLE_EXPORT_NO_OPEN": "1"]
    ) { _, new in new }

    try process.run()
    server = process
  }

  private func waitForServerThenLoad() {
    DispatchQueue.global(qos: .userInitiated).async {
      // Node plus the module graph takes a moment; poll rather than guess.
      for _ in 0..<100 {
        if serverIsUp() {
          DispatchQueue.main.async {
            self.webView.load(URLRequest(url: serverURL))
          }
          return
        }
        if let server = self.server, !server.isRunning {
          DispatchQueue.main.async {
            showFatalError("The server stopped while starting up.")
            NSApp.terminate(nil)
          }
          return
        }
        Thread.sleep(forTimeInterval: 0.1)
      }

      DispatchQueue.main.async {
        showFatalError("The server did not start within 10 seconds.")
        NSApp.terminate(nil)
      }
    }
  }

  /// Quitting mid-export throws away the book in progress — up to an hour of
  /// capture — so ask first. Closing the window is the likeliest way to get
  /// here by accident. If the state can't be read, quit without asking.
  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    guard server?.isRunning == true else { return .terminateNow }

    let request = URLRequest(
      url: serverURL.appendingPathComponent("api/state"), timeoutInterval: 2)
    URLSession.shared.dataTask(with: request) { data, _, _ in
      let busy =
        data
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        .flatMap { $0["busy"] as? String }

      DispatchQueue.main.async {
        guard busy == "export" else {
          NSApp.reply(toApplicationShouldTerminate: true)
          return
        }

        let alert = NSAlert()
        alert.messageText = "A book is still being exported"
        alert.informativeText =
          "Quitting now stops it. Books already finished are kept, and the "
          + "one in progress can be started again later."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        self.showWindow()
        alert.beginSheetModal(for: self.window) { response in
          NSApp.reply(toApplicationShouldTerminate: response == .alertSecondButtonReturn)
        }
      }
    }.resume()

    return .terminateLater
  }

  func applicationWillTerminate(_: Notification) {
    guard let server, server.isRunning else { return }
    server.terminate()
    // Give it a moment to close its listener before the process group dies.
    let deadline = Date().addingTimeInterval(3)
    while server.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if server.isRunning { kill(server.processIdentifier, SIGKILL) }
  }

  // ------------------------------------------------------------------- menu

  private func buildMenu() {
    let mainMenu = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Show Books in Finder",
      action: #selector(showBooks),
      keyEquivalent: "b"
    ).target = self
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: "Hide Kindle Export",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    appMenu.addItem(
      withTitle: "Quit Kindle Export",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    addSubmenu(appMenu, to: mainMenu)

    // Without an Edit menu, ⌘C/⌘V/⌘A do nothing in a web view's text fields —
    // pasting an API key would silently fail.
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
    viewMenu.addItem(
      withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r"
    ).target = self
    addSubmenu(viewMenu, to: mainMenu)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Kindle Export", action: #selector(showWindow), keyEquivalent: "0"
    ).target = self
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m")
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

  @objc private func showBooks() {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outDir.path)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
