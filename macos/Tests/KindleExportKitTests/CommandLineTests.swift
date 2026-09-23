import Foundation
import XCTest

@testable import KindleExportKit

/// The native `book-export` command: parsing, help/version, output, and
/// the app's install-a-link logic. The executable itself only wires these to
/// the terminal and the reader.
final class CommandLineOptionsTests: XCTestCase {
  func run(_ argv: [String]) throws -> CommandLineOptions.Options {
    guard case .run(let options) = try CommandLineOptions.parse(argv) else {
      XCTFail("expected options for \(argv)")
      return CommandLineOptions.Options()
    }
    return options
  }

  func usageError(_ argv: [String]) -> String? {
    do {
      _ = try CommandLineOptions.parse(argv)
      return nil
    } catch {
      return (error as? CommandLineOptions.UsageError)?.message
    }
  }

  func testNoArgumentsPicksFromTheLibrary() throws {
    let options = try run([])
    XCTAssertEqual(options.command, .all)
    XCTAssertEqual(options.asins, [])
    XCTAssertEqual(options.formats, [.md])
    XCTAssertNil(options.outDir)
    XCTAssertFalse(options.forceCapture || options.forceOcr || options.keepPages || options.show)
  }

  func testAsinsAreUppercasedAndChecked() throws {
    XCTAssertEqual(try run(["b01h4g2j1u", " B07PPW5V9C "]).asins, ["B01H4G2J1U", "B07PPW5V9C"])
    // A path would put `clean` outside the books folder.
    XCTAssertEqual(usageError(["clean", ".."]), "invalid ASIN: ..")
    XCTAssertEqual(usageError(["B01-X"]), "invalid ASIN: B01-X")
  }

  func testCommands() throws {
    XCTAssertEqual(try run(["LIST"]).command, .list)
    XCTAssertEqual(try run(["login"]).command, .login)
    XCTAssertEqual(try run(["clean"]).command, .clean)
    XCTAssertEqual(try run(["clean", "B00X"]).asins, ["B00X"])
    let ocr = try run(["ocr", "B00X"])
    XCTAssertEqual(ocr.command, .ocr)
    XCTAssertEqual(ocr.command.pipelineCommand, .transcribe)
    XCTAssertEqual(try run(["capture", "B00X"]).command.pipelineCommand, .capture)
    XCTAssertEqual(try run(["export", "B00X"]).command.pipelineCommand, .export)
    XCTAssertNil(CommandLineOptions.Command.list.pipelineCommand)
    // "all" isn't a command word, as in cli.ts — it reads as an ASIN.
    XCTAssertEqual(try run(["all"]).asins, ["ALL"])

    XCTAssertEqual(usageError(["capture"]), "'capture' needs at least one ASIN")
    XCTAssertEqual(usageError(["list", "B00X"]), "'list' takes no ASINs")
  }

  func testFlags() throws {
    let options = try run([
      "B00X", "--out-dir", "~/books", "--format", "MD, pdf", "--concurrency", "4", "--keep-pages",
      "--show", "--force-ocr",
    ])
    XCTAssertEqual(options.outDir, "~/books")
    XCTAssertEqual(options.formats, [.md, .pdf])
    XCTAssertEqual(options.concurrency, 4)
    XCTAssertTrue(options.keepPages)
    XCTAssertTrue(options.show)
    XCTAssertTrue(options.forceOcr)
    XCTAssertFalse(options.forceCapture)

    let list = try run(["list", "--json", "--limit", "3"])
    XCTAssertTrue(list.json)
    XCTAssertEqual(list.limit, 3)

    XCTAssertEqual(try run(["--format", "pdf,pdf"]).formats, [.pdf])
  }

  func testForceFlags() throws {
    let force = try run(["--force"])
    XCTAssertTrue(force.forceCapture && force.forceOcr)
    // The Node tool's old spelling, and its no-op, keep working.
    XCTAssertTrue(try run(["--force-extract"]).forceCapture)
    let export = try run(["--force-export"])
    XCTAssertFalse(export.forceCapture || export.forceOcr)
  }

  func testPositiveIntegersAreStrict() {
    for bad in ["0", "-3", "1.5", "8x", "", " ", "x", "٣"] {
      XCTAssertEqual(
        usageError(["--concurrency", bad]), "--concurrency requires a positive whole number", bad)
    }
    XCTAssertEqual(usageError(["list", "--limit", "0"]), "--limit requires a positive whole number")
  }

  func testBadInput() {
    XCTAssertEqual(usageError(["--format", "epub"]), "unknown format: epub (expected md or pdf)")
    XCTAssertEqual(usageError(["--format", "md,"]), "unknown format:  (expected md or pdf)")
    XCTAssertEqual(usageError(["--out-dir"]), "--out-dir requires a value")
    XCTAssertEqual(usageError(["--out-dir", " "]), "--out-dir requires a folder")
    XCTAssertEqual(usageError(["--frobnicate"]), "unknown option: --frobnicate")
  }

  func testNodeOnlyOptionsAndCommandsSayWhere() {
    XCTAssertEqual(
      usageError(["ocr", "B00X", "--model", "gpt-5-mini"]),
      "--model is only in the Node version of book-export (pages are read on this Mac with Apple Vision)"
    )
    XCTAssertTrue(usageError(["--profile-dir", "x"])?.contains("Node version") == true)
    XCTAssertTrue(usageError(["serve"])?.contains("open Book Export for Kindle.app") == true)
    XCTAssertTrue(usageError(["setup"])?.contains("book-export login") == true)
  }

  func testHelpAndVersionWin() throws {
    XCTAssertEqual(try CommandLineOptions.parse(["-h"]), .help)
    XCTAssertEqual(try CommandLineOptions.parse(["list", "--help", "--bogus"]), .help)
    XCTAssertEqual(try CommandLineOptions.parse(["-v"]), .version)
    XCTAssertEqual(try CommandLineOptions.parse(["--version"]), .version)
  }

  func testHelpCoversEveryCommandAndOption() {
    let help = CommandLineOptions.help
    XCTAssertTrue(help.hasPrefix("book-export — export Kindle books"))
    for command in ["login", "list", "clean", "capture", "ocr", "export"] {
      XCTAssertTrue(help.contains("book-export \(command)"), command)
    }
    for flag in [
      "--format", "--json", "--limit", "--out-dir", "--concurrency", "--force ", "--force-capture",
      "--force-ocr", "--keep-pages", "--show", "-h, --help", "-v, --version",
    ] {
      XCTAssertTrue(help.contains(flag), flag)
    }
    XCTAssertTrue(help.contains("~/Documents/Kindle Export"))
    // Nothing the native tool doesn't have.
    for gone in ["--model", "--profile-dir", "--port", "serve", "setup"] {
      XCTAssertFalse(help.contains(gone), gone)
    }
  }

  /// The compiled-in version is what an unbundled build reports; the package
  /// script refuses to build when it differs from package.json, and this
  /// catches it sooner.
  func testVersionMatchesPackageJson() throws {
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(contentsOf: repo.appendingPathComponent("package.json"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(json?["version"] as? String, CommandLineOptions.version)
  }

  func testVersionOutsideTheAppIsTheCompiledOne() {
    // The test runner's bundle is not the app's.
    XCTAssertEqual(CommandLineOptions.resolvedVersion(bundle: .main), CommandLineOptions.version)
  }

  func testOutDir() throws {
    let cwd = URL(fileURLWithPath: "/work/here", isDirectory: true)
    let home = FileManager.default.homeDirectoryForCurrentUser
    // Default: the app's folder, so terminal and app share books.
    XCTAssertEqual(
      CommandLineOptions.resolveOutDir(try run([]), environment: [:], cwd: cwd).path,
      home.appendingPathComponent("Documents/Kindle Export").path)
    XCTAssertEqual(
      CommandLineOptions.resolveOutDir(
        try run([]), environment: ["KINDLE_EXPORT_OUT_DIR": "/tmp/books"], cwd: cwd
      ).path, "/tmp/books")
    // A flag beats the environment; relative is to the current directory.
    XCTAssertEqual(
      CommandLineOptions.resolveOutDir(
        try run(["--out-dir", "out"]), environment: ["KINDLE_EXPORT_OUT_DIR": "/tmp/books"],
        cwd: cwd
      ).path, "/work/here/out")
    XCTAssertEqual(
      CommandLineOptions.resolveOutDir(try run(["--out-dir", "~/x"]), environment: [:], cwd: cwd)
        .path, home.appendingPathComponent("x").path)
  }
}

final class CommandLineOutputTests: XCTestCase {
  func texts(_ lines: [CommandLineOutput.Line]) -> [String] { lines.map(\.text) }

  func testEventLines() {
    var renderer = CommandLineOutput.EventRenderer(asin: "B00X")
    XCTAssertEqual(
      renderer.lines(for: .info("capture: opening Kindle reader")),
      [.init("[B00X] capture: opening Kindle reader")])
    XCTAssertEqual(
      renderer.lines(for: .warn("3 of 9 pages could not be read:")),
      [.init("[B00X] 3 of 9 pages could not be read:", isError: true)])
    XCTAssertEqual(renderer.lines(for: .stage(.capture)), [])
  }

  func testTranscribeProgressIsThrottledToTenths() {
    var renderer = CommandLineOutput.EventRenderer(asin: "B00X")
    var printed: [String] = []
    for done in 1...100 {
      printed += texts(renderer.lines(for: .transcribeProgress(done: done, total: 100)))
    }
    XCTAssertEqual(printed.count, 10)
    XCTAssertEqual(printed.first, "[B00X] transcribe: 10/100 pages")
    XCTAssertEqual(printed.last, "[B00X] transcribe: 100/100 pages")
  }

  func testCaptureProgressByPage() {
    var renderer = CommandLineOutput.EventRenderer(asin: "B00X")
    // Nothing until the total is known.
    XCTAssertEqual(renderer.lines(for: .captureProgress(captured: 3, page: nil, total: nil)), [])
    var printed: [String] = []
    for page in 1...116 {
      printed += texts(
        renderer.lines(for: .captureProgress(captured: page * 2, page: page, total: 116)))
    }
    XCTAssertEqual(printed.first, "[B00X] capture: page 1 of 116 (2 screens)")
    XCTAssertEqual(printed.last, "[B00X] capture: page 116 of 116 (232 screens)")
    XCTAssertEqual(printed.count, 11)
  }

  let books = [
    LibraryBook(
      asin: "B09Y7P4DR6", title: "How to Live", authors: ["Derek Sivers"], percentageRead: 42.6),
    LibraryBook(asin: "B00X", title: "Untitled", authors: [], percentageRead: 0),
  ]

  func testListLines() {
    XCTAssertEqual(
      CommandLineOutput.listLines(books),
      [
        "B09Y7P4DR6  How to Live — Derek Sivers (43% read)", "B00X  Untitled", "", "2 books",
      ])
    XCTAssertEqual(CommandLineOutput.listLines([]), ["No books found in your Kindle library."])
    XCTAssertEqual(CommandLineOutput.listLines([books[1]]).last, "1 book")
  }

  func testListJSONIsNodesShape() {
    XCTAssertEqual(
      CommandLineOutput.listJSON([books[1]]),
      """
      [
        {
          "asin": "B00X",
          "title": "Untitled",
          "authors": [],
          "percentageRead": 0
        }
      ]
      """)
  }

  func testPicker() throws {
    XCTAssertEqual(
      CommandLineOutput.pickerLines(books),
      ["1) How to Live — Derek Sivers (43% read)  [B09Y7P4DR6]", "2) Untitled  [B00X]"])
    let many = (1...12).map { LibraryBook(asin: "B\($0)", title: "T\($0)", authors: []) }
    XCTAssertEqual(CommandLineOutput.pickerLines(many)[0], " 1) T1  [B1]")

    XCTAssertEqual(CommandLineOutput.filter(books, by: "sivers").map(\.asin), ["B09Y7P4DR6"])
    XCTAssertEqual(CommandLineOutput.filter(books, by: " ").count, 2)
    XCTAssertEqual(CommandLineOutput.filter(books, by: "nothing"), [])
  }

  func testSelection() throws {
    XCTAssertEqual(try CommandLineOutput.parseSelection("", count: 5), [])
    XCTAssertEqual(try CommandLineOutput.parseSelection("all", count: 3), [0, 1, 2])
    XCTAssertEqual(try CommandLineOutput.parseSelection("3, 1 2-4 3", count: 5), [2, 0, 1, 3])
    XCTAssertThrowsError(try CommandLineOutput.parseSelection("6", count: 5))
    XCTAssertThrowsError(try CommandLineOutput.parseSelection("0", count: 5))
    XCTAssertThrowsError(try CommandLineOutput.parseSelection("4-2", count: 5))
    XCTAssertThrowsError(try CommandLineOutput.parseSelection("one", count: 5))
  }

  func testDuration() {
    XCTAssertEqual(CommandLineOutput.duration(125.9), "2m 5s")
  }
}

final class CommandLineToolTests: XCTestCase {
  var root: URL!
  var target: URL!
  var usrLocalBin: URL!
  var localBin: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cli-install-\(UUID().uuidString)", isDirectory: true)
    let app = root.appendingPathComponent("Applications/Book Export for Kindle.app")
    target = CommandLineTool.bundledTool(appBundle: app)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: target.path, contents: Data("#!/bin/sh\n".utf8))
    usrLocalBin = root.appendingPathComponent("usr/local/bin", isDirectory: true)
    localBin = root.appendingPathComponent("home/.local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: usrLocalBin, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    // Writable again, or the temp directory can't be removed.
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: usrLocalBin.path)
    try? FileManager.default.removeItem(at: root)
  }

  var directories: [URL] { [usrLocalBin, localBin] }

  func readOnly(_ dir: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
  }

  func testBundledToolPath() {
    XCTAssertEqual(
      CommandLineTool.bundledTool(appBundle: URL(fileURLWithPath: "/Applications/Book Export for Kindle.app"))
        .path, "/Applications/Book Export for Kindle.app/Contents/MacOS/book-export")
    XCTAssertEqual(
      CommandLineTool.standardDirectories(home: URL(fileURLWithPath: "/Users/x")).map(\.path),
      ["/usr/local/bin", "/Users/x/.local/bin"])
  }

  func testInstallsInTheFirstWritableDirectory() throws {
    let link = usrLocalBin.appendingPathComponent("book-export")
    XCTAssertEqual(
      CommandLineTool.install(target: target, directories: directories),
      .installed(link: link, fallback: false))
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    XCTAssertEqual(CommandLineTool.state(of: link, target: target), .current)

    // Twice is a no-op.
    XCTAssertEqual(
      CommandLineTool.install(target: target, directories: directories),
      .alreadyInstalled(link: link))
  }

  func testFallsBackToLocalBinWhenUsrLocalBinNeedsRoot() throws {
    try readOnly(usrLocalBin)
    let link = localBin.appendingPathComponent("book-export")
    // ~/.local/bin is created when missing.
    XCTAssertEqual(
      CommandLineTool.install(target: target, directories: directories),
      .installed(link: link, fallback: true))
    XCTAssertEqual(CommandLineTool.state(of: link, target: target), .current)
    XCTAssertEqual(
      CommandLineTool.installedLinks(target: target, directories: directories), [link])
  }

  func testNeedsAdminWhenNothingIsWritable() throws {
    try readOnly(usrLocalBin)
    let blocked = root.appendingPathComponent("blocked", isDirectory: true)
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try readOnly(blocked)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
    }
    let result = CommandLineTool.install(
      target: target, directories: [usrLocalBin, blocked.appendingPathComponent("bin")])
    guard case .needsAdmin(let command) = result else {
      return XCTFail("expected needsAdmin, got \(result)")
    }
    XCTAssertTrue(command.hasPrefix("sudo mkdir -p \(usrLocalBin.path) && sudo ln -sf "), command)
    XCTAssertTrue(command.contains("'\(target.path)'"), command)
  }

  func testNeverReplacesSomethingElse() throws {
    // The Node tool's npm link, say.
    let link = usrLocalBin.appendingPathComponent("book-export")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "../lib/node_modules/kindle-export/dist/cli.js")
    let result = CommandLineTool.install(target: target, directories: directories)
    guard case .conflict(let at, let destination, let command) = result else {
      return XCTFail("expected conflict, got \(result)")
    }
    XCTAssertEqual(at, link)
    XCTAssertEqual(destination, root.appendingPathComponent("usr/local/lib/node_modules/kindle-export/dist/cli.js").standardizedFileURL.path)
    XCTAssertFalse(command.hasPrefix("sudo"), "the folder is writable")
    // Still there, and not ours to uninstall either.
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
      "../lib/node_modules/kindle-export/dist/cli.js")
    XCTAssertEqual(CommandLineTool.uninstall(target: target, directories: directories), .notInstalled)

    // A plain file is foreign too.
    try FileManager.default.removeItem(at: link)
    FileManager.default.createFile(atPath: link.path, contents: Data())
    XCTAssertEqual(CommandLineTool.state(of: link, target: target), .foreign(destination: nil))
  }

  func testReplacesALinkToAnotherCopyOfTheApp() throws {
    // The app was moved (or an older build installed it): the old link
    // points into a bundle that may not even exist any more.
    let link = usrLocalBin.appendingPathComponent("book-export")
    let old = "/Users/x/Downloads/Book Export for Kindle.app/Contents/MacOS/book-export"
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: old)
    XCTAssertEqual(CommandLineTool.state(of: link, target: target), .otherApp(destination: old))
    XCTAssertEqual(
      CommandLineTool.install(target: target, directories: directories),
      .installed(link: link, fallback: false))
    XCTAssertEqual(CommandLineTool.state(of: link, target: target), .current)
  }

  func testUninstallRemovesOnlyOurLinks() throws {
    let ours = usrLocalBin.appendingPathComponent("book-export")
    try FileManager.default.createSymbolicLink(at: ours, withDestinationURL: target)
    let theirs = localBin.appendingPathComponent("book-export")
    try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: theirs.path, withDestinationPath: "/opt/other")

    XCTAssertEqual(
      CommandLineTool.uninstall(target: target, directories: directories), .removed([ours]))
    XCTAssertEqual(CommandLineTool.state(of: ours, target: target), .absent)
    XCTAssertEqual(
      CommandLineTool.state(of: theirs, target: target), .foreign(destination: "/opt/other"))
    // What the link pointed at is untouched.
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    XCTAssertEqual(CommandLineTool.uninstall(target: target, directories: directories), .notInstalled)
  }

  func testUninstallNeedsAdminInARootOwnedFolder() throws {
    let link = usrLocalBin.appendingPathComponent("book-export")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try readOnly(usrLocalBin)
    XCTAssertEqual(
      CommandLineTool.uninstall(target: target, directories: directories),
      .needsAdmin(removed: [], command: "sudo rm \(link.path)"))
  }

  func testShellQuoting() {
    XCTAssertEqual(CommandLineTool.shellQuote("/usr/local/bin"), "/usr/local/bin")
    XCTAssertEqual(
      CommandLineTool.shellQuote("/Applications/Book Export for Kindle.app"),
      "'/Applications/Book Export for Kindle.app'")
    XCTAssertEqual(CommandLineTool.shellQuote("it's"), #"'it'\''s'"#)
    XCTAssertEqual(CommandLineTool.shellQuote(""), "''")
  }
}
