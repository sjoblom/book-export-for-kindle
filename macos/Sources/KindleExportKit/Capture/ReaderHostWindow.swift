import AppKit

/// Where the reader's web view lives while nobody needs to see it: a window
/// that exists for WebKit (a web view renders, and synthesized events reach
/// it, only inside a window) and for nobody else.
///
/// Borderless, ordered in but placed beyond every screen, kept out of the
/// Window menu, Mission Control and ⌘` cycling, never key or main, never
/// minimized — so nothing of it shows on screen or in the Dock. The app's
/// main window borrows the web view when Amazon's sign-in has to be seen, and
/// gives it back here afterwards (`ReaderSession.present(in:)` /
/// `returnToHost()`).
@MainActor
public final class ReaderHostWindow: NSWindow {
  /// How far past the screens' edges the window sits.
  static let margin: CGFloat = 4000

  public init(size: NSSize) {
    super.init(
      contentRect: NSRect(origin: Self.offscreenOrigin(for: size), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    title = "Kindle reader"
    isReleasedWhenClosed = false
    isExcludedFromWindowsMenu = true
    collectionBehavior = [.transient, .ignoresCycle]
    // The person's own mouse can never land here; synthesized events are
    // handed to the window directly and don't go through hit-testing.
    ignoresMouseEvents = true
    hasShadow = false
    animationBehavior = .none
    acceptsMouseMovedEvents = true
  }

  override public var canBecomeKey: Bool { false }
  override public var canBecomeMain: Bool { false }

  /// A point that puts a window of `size` entirely outside every screen
  /// (below and to the left of all of them), however they are arranged.
  public static func offscreenOrigin(for size: NSSize, screens: [NSRect]? = nil) -> NSPoint {
    let frames = screens ?? NSScreen.screens.map(\.frame)
    let union = frames.reduce(NSRect.zero) { $0.union($1) }
    return NSPoint(x: union.minX - size.width - margin, y: union.minY - size.height - margin)
  }

  /// How the window keeps WebKit rendering while nobody can see it.
  public enum Mode: String, Sendable {
    /// Beyond every screen. WebKit then thinks the page is hidden
    /// (`document.visibilityState` "hidden", no `requestAnimationFrame`) and
    /// the reader never lays out its controls — unless the web view's window
    /// occlusion detection is switched off, which `ReaderSession` does. Tried
    /// and verified with a full capture (September 2026).
    case offscreen
    /// Fallback where occlusion detection can't be switched off: a single
    /// point of the window overlaps the main screen's bottom-left corner, at
    /// 1% opacity, below the desktop picture. WindowServer counts it as
    /// visible, so WebKit renders; nobody can see it.
    case sliver
  }

  public var mode: Mode = .offscreen

  /// Order the window in, out of sight — alive for WebKit, invisible to the
  /// person. Screens may have been rearranged since it was placed.
  public func orderInOffscreen() {
    let origin: NSPoint
    switch mode {
    case .offscreen:
      alphaValue = 1
      level = .normal
      origin = Self.offscreenOrigin(for: frame.size)
    case .sliver:
      alphaValue = 0.01
      level = Self.belowDesktop
      let screen = NSScreen.screens.first?.frame ?? .zero
      origin = NSPoint(x: screen.minX - frame.width + 1, y: screen.minY - frame.height + 1)
    }
    if frame.origin != origin { setFrameOrigin(origin) }
    if !isVisible { orderBack(nil) }
  }

  static let belowDesktop = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

  /// Whether the window is anywhere a person could see it.
  public var isOnAnyScreen: Bool {
    NSScreen.screens.contains { $0.frame.intersects(frame) }
  }
}
