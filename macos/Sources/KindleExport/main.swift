import AppKit
import KindleExportKit

// Kindle Export.app — the native app (see ../../PLAN.md, "Wave 2").
//
// One process, two windows: the main window shows the UI page (the same page
// `kindle-export serve` serves, talking to AppModel through the bridge), and
// the "Amazon" window hosts the Kindle reader web view, parked in the Dock
// except while the person signs in.

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  withExtendedLifetime(delegate) { app.run() }
}
