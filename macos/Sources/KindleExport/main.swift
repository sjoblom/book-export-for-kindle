import AppKit
import KindleExportKit

// Kindle Export.app — the native app (see ../../PLAN.md, "Wave 2").
//
// One process, one visible window: it shows the UI page (the same page
// `kindle-export serve` serves, talking to AppModel through the bridge), or,
// while Amazon wants a sign-in, Amazon's page under a native bar. The Kindle
// reader web view otherwise lives in an invisible off-screen host window.

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  withExtendedLifetime(delegate) { app.run() }
}
