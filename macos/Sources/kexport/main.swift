import AppKit
import Foundation
import KindleExportKit

// kexport — developer tool for the native capture.
//
//   kexport capture <ASIN> --out <dir> [--show] [--sign-in-timeout <seconds>]
//
// Runs the reader in its own window (minimized unless --show), captures the
// book into <dir>/<ASIN>/ exactly as the app would, prints progress, and exits
// 0 when the capture completed, 1 otherwise. If Amazon asks for a sign-in the
// window is shown and the person has --sign-in-timeout seconds (default 300;
// 0 = fail at once) to complete it.
//
// Note: WKWebsiteDataStore.default() is per executable, so kexport keeps its
// own Amazon session, separate from the app's.

func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      """
      usage: kexport capture <ASIN> --out <dir> [--show] [--sign-in-timeout <seconds>]

      """.utf8))
  exit(2)
}

struct Arguments {
  var asin: String
  var outDir: URL
  var show = false
  var signInTimeout: TimeInterval = 300
}

func parseArguments() -> Arguments {
  var args = Array(CommandLine.arguments.dropFirst())
  guard args.first == "capture" else { usage() }
  args.removeFirst()

  var asin: String?
  var out: String?
  var show = false
  var signInTimeout: TimeInterval = 300
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--out":
      guard !args.isEmpty else { usage() }
      out = args.removeFirst()
    case "--show":
      show = true
    case "--sign-in-timeout":
      guard !args.isEmpty, let value = TimeInterval(args.removeFirst()) else { usage() }
      signInTimeout = value
    case "-h", "--help":
      usage()
    default:
      if arg.hasPrefix("-") || asin != nil { usage() }
      asin = arg
    }
  }
  guard let asin, let out else { usage() }
  return Arguments(
    asin: asin, outDir: URL(fileURLWithPath: out, isDirectory: true), show: show,
    signInTimeout: signInTimeout)
}

func log(_ line: String) {
  let stamp = ISO8601DateFormatter.string(
    from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
  FileHandle.standardError.write(Data("[\(stamp)] \(line)\n".utf8))
}

@MainActor
final class Runner: NSObject, NSApplicationDelegate {
  let arguments: Arguments
  var task: Task<Void, Never>?
  var session: ReaderSession?
  var signals: [DispatchSourceSignal] = []

  init(arguments: Arguments) { self.arguments = arguments }

  func applicationDidFinishLaunching(_: Notification) {
    installMenu()
    for sig in [SIGINT, SIGTERM] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [weak self] in
        log("interrupted; stopping the capture...")
        MainActor.assumeIsolated { self?.task?.cancel() }
      }
      source.resume()
      signals.append(source)
    }

    task = Task { @MainActor in
      let code = await self.capture()
      exit(code)
    }
  }

  func capture() async -> Int32 {
    let core: JSCore
    do {
      core = try JSCore()
    } catch {
      log("error: \(error)")
      return 1
    }

    let session = ReaderSession()
    self.session = session
    session.window.title = "kexport — \(arguments.asin)"
    session.log = { log("session: \($0)") }
    if arguments.show { session.show() } else { session.minimize() }

    let engine = CaptureEngine(
      session: session, options: CaptureEngine.Options(asin: arguments.asin, outDir: arguments.outDir),
      core: core)
    engine.onEvent = { event in
      switch event {
      case .message(let message): log(message)
      case .progress(let p):
        log("progress: \(p.screens) screens, page \(p.page) of \(p.totalContentPages)")
      case .needsSignIn: log("sign-in needed")
      }
    }
    let show = arguments.show
    let timeout = arguments.signInTimeout
    engine.signInHandler = { session in
      guard timeout > 0 else { throw CaptureEngine.CaptureError.needsSignIn }
      session.show()
      log("sign in to Amazon in the window (waiting up to \(Int(timeout)) s)...")
      try await session.waitForSignIn(timeout: timeout)
      if !show { session.minimize() }
    }

    do {
      let result = try await engine.run()
      log(
        "capture \(result.complete ? "complete" : "incomplete"): \(result.reason), "
          + "last page \(result.lastPage) of \(result.totalContentPages)"
          + (result.recoveries.map { ", \($0.count) recoveries" } ?? ""))
      return result.complete ? 0 : 1
    } catch is CancellationError {
      log("capture cancelled")
      return 1
    } catch {
      log("error: \(error)")
      return 1
    }
  }

  /// Paste in the sign-in form needs an Edit menu.
  func installMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit kexport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    NSApp.mainMenu = main
  }
}

let arguments = parseArguments()
MainActor.assumeIsolated {
  let app = NSApplication.shared
  let runner = Runner(arguments: arguments)
  app.delegate = runner
  app.setActivationPolicy(.regular)
  withExtendedLifetime(runner) { app.run() }
}
