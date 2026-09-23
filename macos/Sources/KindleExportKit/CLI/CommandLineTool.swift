import Foundation

/// Putting the bundled `kindle-export` on the PATH: the app menu's "Install
/// Command-Line Tool…" and "Uninstall Command-Line Tool…".
///
/// The tool is a symlink to `Kindle Export.app/Contents/MacOS/kindle-export`,
/// not a copy: the tool must run from inside the app to share its Amazon
/// sign-in (see KindleExportCLI/main.swift), and a link follows the app
/// through updates. The app never asks for an administrator password — where
/// no folder on the list is writable it shows the one `sudo` line to run.
public enum CommandLineTool {
  public static let name = CommandLineOptions.programName

  /// The tool inside an app bundle.
  public static func bundledTool(appBundle: URL) -> URL {
    appBundle.appendingPathComponent("Contents/MacOS/\(name)")
  }

  /// Where the link goes, in order of preference: /usr/local/bin is on every
  /// Mac's default PATH (/etc/paths) but belongs to root unless Homebrew (on
  /// Intel) took it over; ~/.local/bin is always the person's own.
  public static func standardDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> [URL]
  {
    [
      URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
      home.appendingPathComponent(".local/bin", isDirectory: true),
    ]
  }

  /// What is at a link location now.
  public enum LinkState: Equatable, Sendable {
    case absent
    /// A link to exactly this tool.
    case current
    /// A link to another copy of the app's tool (an old location, another
    /// build): ours to replace or remove.
    case otherApp(destination: String)
    /// Something else — the Node tool's npm link, a script someone wrote.
    /// Never replaced or removed.
    case foreign(destination: String?)
  }

  public static func linkURL(in directory: URL) -> URL {
    directory.appendingPathComponent(name)
  }

  public static func state(of link: URL, target: URL) -> LinkState {
    let fm = FileManager.default
    guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
      // Not a link: either nothing, or a real file that isn't ours.
      return entryExists(link) ? .foreign(destination: nil) : .absent
    }
    let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
      .standardizedFileURL.path
    if resolved == target.standardizedFileURL.path { return .current }
    if isAppTool(resolved) { return .otherApp(destination: resolved) }
    return .foreign(destination: resolved)
  }

  /// `…/Something.app/Contents/MacOS/kindle-export`.
  static func isAppTool(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    let macOS = url.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    return url.lastPathComponent == name && macOS.lastPathComponent == "MacOS"
      && contents.lastPathComponent == "Contents"
      && contents.deletingLastPathComponent().pathExtension == "app"
  }

  /// lstat, because fileExists follows links and calls a broken one absent.
  static func entryExists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
  }

  public enum InstallResult: Equatable, Sendable {
    /// `fallback` when it went somewhere other than the first directory,
    /// which may not be on the person's PATH.
    case installed(link: URL, fallback: Bool)
    case alreadyInstalled(link: URL)
    /// Something that isn't ours has the name in the preferred directory.
    case conflict(link: URL, destination: String?, command: String)
    /// No directory could take the link; `command` does it as root.
    case needsAdmin(command: String)
  }

  public static func install(target: URL, directories: [URL]) -> InstallResult {
    for directory in directories where state(of: linkURL(in: directory), target: target) == .current {
      return .alreadyInstalled(link: linkURL(in: directory))
    }
    guard let preferred = directories.first else {
      return .needsAdmin(command: "")
    }

    // A foreign kindle-export (most likely the Node tool's) first on the
    // PATH would shadow a link placed anywhere later, so installing past it
    // would look like success and change nothing.
    let preferredLink = linkURL(in: preferred)
    if case .foreign(let destination) = state(of: preferredLink, target: target) {
      return .conflict(
        link: preferredLink, destination: destination,
        command: linkCommand(target: target, directory: preferred, sudo: !isWritable(preferred)))
    }

    for (offset, directory) in directories.enumerated() {
      let link = linkURL(in: directory)
      let current = state(of: link, target: target)
      if case .foreign = current { continue }
      guard prepare(directory) else { continue }
      do {
        if case .otherApp = current { try FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return .installed(link: link, fallback: offset > 0)
      } catch {
        continue
      }
    }
    return .needsAdmin(command: linkCommand(target: target, directory: preferred, sudo: true))
  }

  /// Links of ours (to this tool or another copy of the app's) in `directories`.
  public static func installedLinks(target: URL, directories: [URL]) -> [URL] {
    directories.map(linkURL(in:)).filter {
      switch state(of: $0, target: target) {
      case .current, .otherApp: return true
      case .absent, .foreign: return false
      }
    }
  }

  public enum UninstallResult: Equatable, Sendable {
    case notInstalled
    case removed([URL])
    /// Some links need root to remove; `removed` went already.
    case needsAdmin(removed: [URL], command: String)
  }

  public static func uninstall(target: URL, directories: [URL]) -> UninstallResult {
    let links = installedLinks(target: target, directories: directories)
    guard !links.isEmpty else { return .notInstalled }
    var removed: [URL] = []
    var stuck: [URL] = []
    for link in links {
      // unlink(), not removeItem: it removes the link itself, never what it
      // points at.
      if unlink(link.path) == 0 { removed.append(link) } else { stuck.append(link) }
    }
    if stuck.isEmpty { return .removed(removed) }
    return .needsAdmin(
      removed: removed, command: "sudo rm " + stuck.map { shellQuote($0.path) }.joined(separator: " "))
  }

  // MARK: - helpers

  static func isWritable(_ directory: URL) -> Bool {
    FileManager.default.isWritableFile(atPath: directory.path)
  }

  /// Make sure `directory` exists and can take a new entry.
  static func prepare(_ directory: URL) -> Bool {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    if !fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
      guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
      else { return false }
      return true
    }
    return isDirectory.boolValue && isWritable(directory)
  }

  /// The line to paste into Terminal. `ln -sf` replaces whatever is there,
  /// which is the point when the person runs it by hand.
  public static func linkCommand(target: URL, directory: URL, sudo: Bool) -> String {
    let prefix = sudo ? "sudo " : ""
    return "\(prefix)mkdir -p \(shellQuote(directory.path)) && \(prefix)ln -sf "
      + "\(shellQuote(target.path)) \(shellQuote(linkURL(in: directory).path))"
  }

  /// Single quotes, with any single quote inside closed, escaped and reopened.
  public static func shellQuote(_ text: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+=:@%"))
    if !text.isEmpty, text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
    return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }
}
