import AppKit
import Foundation
import KindleExportKit

// book-export — the command-line side of Book Export for Kindle.app (see
// ../../PLAN.md, "Command-line tool"). The same engine as the app: the
// reader in a WKWebView, Vision for the text, KindleCore for everything
// shared with the Node tool. Commands and flags follow src/cli.ts.
//
// It ships inside the app, as `Book Export for Kindle.app/Contents/MacOS/book-export`,
// because that is how it shares the app's Amazon sign-in: WebKit keeps
// `WKWebsiteDataStore.default()` — cookies included — per bundle identifier
// (~/Library/HTTPStorages/<id>.binarycookies), and a process gets the app's
// identifier only when its executable sits in the bundle's Contents/MacOS.

/// Run again from the real file when started through a symlink.
///
/// The PATH link (/usr/local/bin/book-export, made by the app's "Install
/// Command-Line Tool…") is the usual way in. Bundle.main is worked out from
/// the path the process was started with and does not resolve links, so run
/// as the link the tool has no bundle — and WebKit would give it an empty
/// data store of its own (named after the process), signed out. Measured
/// September 2026: through a link, `Bundle.main.bundleIdentifier` is nil;
/// from the resolved path it is the app's, and the app's cookies are there.
func reexecFromRealPathIfLinked() {
  let marker = "KINDLE_EXPORT_REEXEC"
  if getenv(marker) != nil {
    // Once is enough; don't hand the marker to anything this process starts.
    unsetenv(marker)
    return
  }
  var size: UInt32 = 0
  _ = _NSGetExecutablePath(nil, &size)
  var buffer = [CChar](repeating: 0, count: Int(size) + 1)
  guard _NSGetExecutablePath(&buffer, &size) == 0, let real = realpath(buffer, nil) else { return }
  defer { free(real) }
  guard strcmp(buffer, real) != 0 else { return }
  setenv(marker, "1", 1)
  // argv[0] becomes the real path too: it is what `ps` — and so the book
  // lock's check that an owner is still book-export — sees, and a link can
  // be named anything.
  let argv = CommandLine.unsafeArgv
  argv[0] = real
  execv(real, argv)
  // Still here: exec failed. Carry on as we are — signed out at worst.
  unsetenv(marker)
}

reexecFromRealPathIfLinked()

// Which bundle — and so which Amazon session — this run has; the package
// script's smoke test checks it through a symlink.
if ProcessInfo.processInfo.environment["KINDLE_EXPORT_DEBUG"] == "1" {
  Terminal.error(
    "book-export: bundle \(Bundle.main.bundleIdentifier ?? "none") at \(Bundle.main.bundlePath)")
}

let parsed: CommandLineOptions.Parsed
do {
  parsed = try CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  // A usage error deserves one line, not a trace.
  Terminal.error("book-export: \(Terminal.describe(error))")
  Terminal.error("Run 'book-export --help' for usage.")
  exit(1)
}

switch parsed {
case .help:
  Terminal.print(CommandLineOptions.help)
  exit(0)
case .version:
  Terminal.print(CommandLineOptions.resolvedVersion())
  exit(0)
case .run(let options):
  let environment = ProcessInfo.processInfo.environment
  let outDir = CommandLineOptions.resolveOutDir(
    options, environment: environment,
    cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
  MainActor.assumeIsolated {
    let runner = Runner(options: options, outDir: outDir)
    if runner.usesAppKit {
      // The reader's web view needs windows, so an application — but one
      // that stays out of the Dock and doesn't take focus from the terminal
      // until Amazon's sign-in has to be shown.
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      app.delegate = runner
      withExtendedLifetime(runner) { app.run() }
    } else {
      // Transcribing, exporting and cleaning touch no window.
      runner.start()
      withExtendedLifetime(runner) { dispatchMain() }
    }
  }
}
