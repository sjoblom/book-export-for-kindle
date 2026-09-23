import AppKit
import Foundation
import KindleExportKit

/// Developer option: export one book end to end with nobody at the keyboard,
/// the way a click would, then write what happened and quit.
///
///     KINDLE_EXPORT_AUTOTEST=<ASIN> [KINDLE_EXPORT_OUT_DIR=<dir>] \
///       "Kindle Export.app/Contents/MacOS/Kindle Export"
///
/// Waits for the launch-time library read, enqueues the ASIN through the same
/// route the page uses (`POST /api/export`), waits for the queue to finish and
/// writes `<outDir>/autotest-result.json`. It never signs in: if Amazon wants
/// a sign-in, the result says so and the app quits. Unset, it does nothing.
///
/// `KINDLE_EXPORT_DEBUG_READER=1` also logs, every 3 s during the export,
/// what the reader page looks like to WebKit (visibility, animation frames,
/// the settings button's box) — how the off-screen hosting was diagnosed.
@MainActor
enum Autotest {
  static let libraryTimeout: TimeInterval = 180
  static let exportTimeout: TimeInterval = 3 * 60 * 60

  static func startIfAsked(model: AppModel, backend: NativeBackend, environment: AppEnvironment) {
    guard let asin = ProcessInfo.processInfo.environment["KINDLE_EXPORT_AUTOTEST"], !asin.isEmpty
    else { return }
    let resultURL = environment.outDir.appendingPathComponent("autotest-result.json")
    try? FileManager.default.removeItem(at: resultURL)
    let started = Date()
    log("autotest: \(asin) → \(environment.outDir.path)")

    Task { @MainActor in
      var result: [String: Any] = ["asin": asin, "outDir": environment.outDir.path]
      defer {
        result["seconds"] = Int(Date().timeIntervalSince(started))
        write(result, to: resultURL)
        log("autotest: done (\(result["status"] ?? "?")) → \(resultURL.path)")
        NSApp.terminate(nil)
      }

      // The launch-time library read: done when the session is free again.
      // A sign-in page means the session is signed out — not ours to answer.
      let libraryDeadline = Date().addingTimeInterval(libraryTimeout)
      try? await Task.sleep(nanoseconds: 500_000_000)
      while model.busy != nil || (model.amazon == .unknown && model.libraryError == nil) {
        if model.amazon == .signingIn || backend.signingIn {
          backend.cancelSignIn()
          result["status"] = "signed-out"
          return
        }
        if Date() > libraryDeadline {
          result["status"] = "library-timeout"
          return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
      result["amazon"] = model.amazon.rawValue
      if let error = model.libraryError { result["libraryError"] = error }
      guard model.amazon == .signedIn else {
        result["status"] = "signed-out"
        return
      }

      let reply = await model.handle(method: "POST", path: "/api/export", body: ["asin": asin])
      guard reply.status == 202 else {
        result["status"] = "rejected"
        result["reply"] = reply.status
        return
      }

      if ProcessInfo.processInfo.environment["KINDLE_EXPORT_DEBUG_READER"] == "1" {
        Task { @MainActor in
          while true {
            _ = await backend.session.evaluate("if (!window.__kxRafOn) { window.__kxRafOn = 1; const f = () => { window.__kxRaf = (window.__kxRaf || 0) + 1; requestAnimationFrame(f) }; requestAnimationFrame(f) }")
            let probe = await backend.session.evaluate("""
              (() => { const b = document.querySelector('ion-button[aria-label="Reader settings"], button[aria-label="Reader settings"]');
                const r = b && b.getBoundingClientRect();
                return JSON.stringify({vis: document.visibilityState, focus: document.hasFocus(), w: innerWidth, h: innerHeight,
                  url: location.pathname, btn: !!b, rect: r ? [r.x, r.y, r.width, r.height] : null,
                  imgs: document.querySelectorAll('img').length, raf: window.__kxRaf || 0}) })()
              """)
            let window = backend.session.window
            log("probe: \(probe ?? "nil") occl=\(window.occlusionState.rawValue) frame=\(window.frame)")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
          }
        }
      }

      let exportDeadline = Date().addingTimeInterval(exportTimeout)
      var current: BookJob? { model.books.first { $0.asin == asin } }
      while !(current?.status.isFinished ?? true) || model.busy == .export {
        if backend.signingIn {
          backend.cancelSignIn()
          result["signInAskedMidExport"] = true
        }
        if Date() > exportDeadline {
          result["status"] = "export-timeout"
          return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }

      guard let job = current else {
        result["status"] = "missing"
        return
      }
      result["status"] = job.status.rawValue
      result["title"] = job.title
      result["outputs"] = job.outputs
      result["warnings"] = job.warnings
      if let error = job.error { result["error"] = error }
      if let captured = job.captured { result["capturedScreens"] = captured }
      if let page = job.capturedPage { result["capturedPage"] = page }
      if let total = job.capturedTotal { result["capturedTotal"] = total }
      if let done = job.transcribed { result["transcribed"] = done }

      if let status = model.diskBooks.first(where: { $0.asin == asin }),
        let data = try? JSONEncoder().encode(status.completeness),
        let completeness = try? JSONSerialization.jsonObject(with: data)
      {
        result["completeness"] = completeness
      }
      let metadataURL = environment.outDir.appendingPathComponent("\(asin)/metadata.json")
      if let data = try? Data(contentsOf: metadataURL),
        let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        result["pageCount"] = (metadata["pages"] as? [Any])?.count
        result["capture"] = metadata["capture"]
        result["nav"] = metadata["nav"]
      }
    }
  }

  static func write(_ result: [String: Any], to url: URL) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  static func log(_ line: String) {
    FileHandle.standardError.write(Data("[kindle-export] \(line)\n".utf8))
  }
}
