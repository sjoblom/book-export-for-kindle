import AppKit
import KindleExportKit

/// The app menu's "Install Command-Line Tool…" and "Uninstall Command-Line
/// Tool…": a `book-export` link on the PATH to the tool inside this app
/// (the logic, and why it is a link, in `CommandLineTool`).
///
/// Nothing here runs as root. Where a folder needs an administrator, the
/// alert shows the one line to paste into Terminal, with a button that copies
/// it.
@MainActor
final class CommandLineToolMenu: NSObject, NSMenuItemValidation {
  private let directories: [URL]
  private let appBundle: URL

  init(
    appBundle: URL = Bundle.main.bundleURL,
    directories: [URL] = CommandLineTool.standardDirectories()
  ) {
    self.appBundle = appBundle
    self.directories = directories
  }

  private var tool: URL { CommandLineTool.bundledTool(appBundle: appBundle) }

  func addItems(to menu: NSMenu) {
    menu.addItem(
      withTitle: "Install Command-Line Tool…", action: #selector(install), keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "Uninstall Command-Line Tool…", action: #selector(uninstall), keyEquivalent: ""
    ).target = self
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(uninstall) {
      return !CommandLineTool.installedLinks(target: tool, directories: directories).isEmpty
    }
    return true
  }

  @objc private func install() {
    guard FileManager.default.isExecutableFile(atPath: tool.path) else {
      // A development build (`swift run KindleExport`) has no bundle to link to.
      show(
        "This copy of Book Export for Kindle has no command-line tool",
        "It is part of the app built with 'pnpm package'. Expected it at \(tool.path).")
      return
    }

    let confirm = NSAlert()
    confirm.messageText = "Install the book-export command?"
    confirm.informativeText =
      "Terminal gets a 'book-export' command that exports books like this app does — "
      + "with the same Amazon sign-in and the same books folder. It is a link to the tool "
      + "inside Book Export for Kindle, placed in /usr/local/bin (or ~/.local/bin if that folder "
      + "needs an administrator)."
    confirm.addButton(withTitle: "Install")
    confirm.addButton(withTitle: "Cancel")
    guard confirm.runModal() == .alertFirstButtonReturn else { return }

    switch CommandLineTool.install(target: tool, directories: directories) {
    case .installed(let link, let fallback):
      var text = "Try it in Terminal: book-export --help"
      if fallback {
        let directory = link.deletingLastPathComponent().path
        text =
          "Installed as \(link.path), because /usr/local/bin needs an administrator.\n\n"
          + "If Terminal says “command not found”, add \(directory) to your PATH — for zsh, "
          + "add this line to ~/.zshrc:\n\nexport PATH=\"\(directory):$PATH\""
        let command = CommandLineTool.linkCommand(
          target: tool, directory: directories[0], sudo: true)
        show("book-export is installed", text, copying: command, copyTitle: "Copy sudo Command")
      } else {
        show("book-export is installed", "Installed as \(link.path). " + text)
      }
    case .alreadyInstalled(let link):
      show("book-export is already installed", "It is at \(link.path).")
    case .conflict(let link, let destination, let command):
      let what = destination.map { "a link to \($0)" } ?? "a file"
      show(
        "Another book-export is in the way",
        "\(link.path) is already \(what) — perhaps the Node version of book-export. "
          + "Book Export for Kindle leaves it alone. To replace it with this app's tool, run this in "
          + "Terminal:\n\n\(command)",
        copying: command)
    case .needsAdmin(let command):
      show(
        "Installing needs an administrator",
        "Neither /usr/local/bin nor ~/.local/bin could take the link. Run this in Terminal:"
          + "\n\n\(command)",
        copying: command)
    }
  }

  @objc private func uninstall() {
    switch CommandLineTool.uninstall(target: tool, directories: directories) {
    case .notInstalled:
      show("book-export is not installed", "There is no book-export link to remove.")
    case .removed(let links):
      show(
        "book-export is uninstalled",
        "Removed \(links.map(\.path).joined(separator: ", ")). Your books are untouched.")
    case .needsAdmin(let removed, let command):
      let done = removed.isEmpty ? "" : "Removed \(removed.map(\.path).joined(separator: ", ")). "
      show(
        "Uninstalling needs an administrator",
        done + "To remove the rest, run this in Terminal:\n\n\(command)", copying: command)
    }
  }

  private func show(
    _ title: String, _ text: String, copying command: String? = nil,
    copyTitle: String = "Copy Command"
  ) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.addButton(withTitle: "OK")
    if command != nil { alert.addButton(withTitle: copyTitle) }
    if alert.runModal() == .alertSecondButtonReturn, let command {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
    }
  }
}
