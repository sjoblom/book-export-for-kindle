import Foundation
import XCTest

@testable import KindleExportKit

final class PipelineLockTests: XCTestCase {
  private func ownerFiles(_ bookDir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: BookLock.lockPath(bookDir).path)) ?? []
  }

  /// A lock as another run (Node or app) would leave it.
  private func plantOwner(_ bookDir: URL, pid: Int32, token: String = "other-token") throws {
    let lock = BookLock.lockPath(bookDir)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    let owner = """
      {
        "pid": \(pid),
        "token": "\(token)",
        "startedAt": "2026-09-23T10:00:00.000Z",
        "command": "all"
      }
      """
    try owner.write(
      to: lock.appendingPathComponent("owner-\(pid)-\(token).json"), atomically: true,
      encoding: .utf8)
  }

  func testTakesAndReleasesWithNodeCompatibleNames() async throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    let seen: [String] = try await BookLock.withLock(bookDir: bookDir, command: "test") {
      ownerFiles(bookDir)
    }
    XCTAssertEqual(seen.count, 1)
    let name = try XCTUnwrap(seen.first)
    XCTAssertTrue(
      name.range(
        of: #"^owner-\#(getpid())-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$"#,
        options: .regularExpression) != nil, name)

    // Released: no .lock, no staging directories left behind.
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bookDir.path), [])
  }

  func testOwnerFileContents() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    let handle = try BookLock.acquire(bookDir: bookDir, command: "app all")
    defer { handle.release() }
    let data = try Data(
      contentsOf: BookLock.lockPath(bookDir).appendingPathComponent(handle.ownerFileName))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["pid"] as? Int, Int(getpid()))
    XCTAssertEqual(object["command"] as? String, "app all")
    XCTAssertNotNil(object["token"] as? String)
    XCTAssertTrue((object["startedAt"] as? String)?.hasSuffix("Z") == true)
  }

  func testReleasesWhenBodyThrows() async throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    struct Boom: Error {}
    do {
      _ = try await BookLock.withLock(bookDir: bookDir) { () async throws -> Int in throw Boom() }
      XCTFail("expected a throw")
    } catch is Boom {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: BookLock.lockPath(bookDir).path))
  }

  func testBusyWhenALiveKindleExportHoldsIt() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    // This test process stands in for another run: alive, and its command
    // line (as the probe reports it) is a Node kindle-export.
    try plantOwner(bookDir, pid: getpid())
    let probes = BookLock.Probes(
      isAlive: { BookLock.isProcessAlive($0) }, commandLine: { _ in "node dist/cli.js B0X" })

    XCTAssertThrowsError(try BookLock.acquire(bookDir: bookDir, probes: probes)) { error in
      let busy = error as? BookBusyError
      XCTAssertEqual(busy?.pid, getpid())
      XCTAssertEqual(busy?.command, "all")
      XCTAssertTrue(busy?.localizedDescription.contains("is working on this book") == true)
    }
    // The other owner's lock is untouched.
    XCTAssertEqual(ownerFiles(bookDir), ["owner-\(getpid())-other-token.json"])
  }

  func testUnreadableCommandLineCountsAsLive() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    try plantOwner(bookDir, pid: getpid())
    let probes = BookLock.Probes(isAlive: { _ in true }, commandLine: { _ in nil })
    XCTAssertThrowsError(try BookLock.acquire(bookDir: bookDir, probes: probes))
  }

  func testRecoversADeadOwner() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    // A pid far above anything running.
    try plantOwner(bookDir, pid: 99_999_999 % Int32.max)
    XCTAssertFalse(BookLock.isProcessAlive(99_999_999))

    let handle = try BookLock.acquire(bookDir: bookDir)
    XCTAssertEqual(ownerFiles(bookDir), [handle.ownerFileName])
    handle.release()
    XCTAssertFalse(FileManager.default.fileExists(atPath: BookLock.lockPath(bookDir).path))
  }

  func testRecoversARecycledPid() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    try plantOwner(bookDir, pid: getpid())
    // Alive, but plainly not ours.
    let probes = BookLock.Probes(isAlive: { _ in true }, commandLine: { _ in "/usr/bin/vim notes" })
    let handle = try BookLock.acquire(bookDir: bookDir, probes: probes)
    XCTAssertEqual(ownerFiles(bookDir), [handle.ownerFileName])
    handle.release()
  }

  func testRecoversEmptyLockAndOldStyleFile() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    let lock = BookLock.lockPath(bookDir)

    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    try BookLock.acquire(bookDir: bookDir).release()

    try #"{"pid": 99999999}"#.write(to: lock, atomically: true, encoding: .utf8)
    let handle = try BookLock.acquire(bookDir: bookDir)
    var isDir: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path, isDirectory: &isDir))
    XCTAssertTrue(isDir.boolValue)
    handle.release()
  }

  func testSecondAcquireInProcessIsBusy() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    let first = try BookLock.acquire(bookDir: bookDir)
    defer { first.release() }
    // Our own live pid; the real probes see an xctest process, so claim to be the app.
    let probes = BookLock.Probes(
      isAlive: { BookLock.isProcessAlive($0) },
      commandLine: { _ in "/Applications/Kindle Export.app/Contents/MacOS/KindleExport" })
    XCTAssertThrowsError(try BookLock.acquire(bookDir: bookDir, probes: probes))
  }

  /// Start `path` with `argv0` as its command name — what `ps` and the
  /// command-line probe then report — and return its pid.
  private func spawn(_ path: String, argv0: String, _ args: [String]) throws -> pid_t {
    var pid: pid_t = 0
    let argv = ([argv0] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let status = posix_spawn(&pid, path, nil, nil, argv, environ)
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    return pid
  }

  private func stop(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
  }

  /// kexport takes the lock for its captures; a live one must keep the app
  /// (and Node, which shares the pattern) out, judged by the real probes.
  func testBusyWhenALiveKexportHoldsIt() throws {
    let bookDir = try PipelineFixtures.tempDir("lock")
    // Installed away from the repo, so no "kindle-export" in its path can
    // match for it.
    let pid = try spawn("/bin/sleep", argv0: "/opt/tools/kexport", ["30"])
    defer { stop(pid) }
    try plantOwner(bookDir, pid: pid)
    XCTAssertEqual(BookLock.processCommandLine(pid), "/opt/tools/kexport 30")

    XCTAssertThrowsError(try BookLock.acquire(bookDir: bookDir)) { error in
      XCTAssertEqual((error as? BookBusyError)?.pid, pid)
    }

    stop(pid)
    // Gone, so its lock is stale.
    try BookLock.acquire(bookDir: bookDir).release()
  }

  /// The two implementations against each other: a real Node process holds
  /// the lock through book-lock.ts, and the native one must see it as busy,
  /// then take it once Node lets go.
  func testNodeHoldingTheLockKeepsTheNativeSideOut() async throws {
    let root = PipelineFixtures.repoRoot
    let tsx = root.appendingPathComponent("node_modules/tsx")
    let path = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
      .joined(separator: ":")
    let node = path.split(separator: ":").map { "\($0)/node" }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let node, FileManager.default.fileExists(atPath: tsx.path) else {
      throw XCTSkip("node and the repo's node_modules (tsx) are needed")
    }

    let bookDir = try PipelineFixtures.tempDir("lock")
    let work = try PipelineFixtures.tempDir("lock-node")
    let ready = work.appendingPathComponent("ready")
    let release = work.appendingPathComponent("release")
    let script = work.appendingPathComponent("hold.mts")
    let bookLock = root.appendingPathComponent("src/book-lock.ts").path
    try """
      import fs from 'node:fs/promises'
      import { withBookLock } from \(String(reflecting: bookLock))
      const [bookDir, ready, release] = process.argv.slice(2)
      const exists = (p) => fs.access(p).then(() => true, () => false)
      await withBookLock(bookDir, async () => {
        await fs.writeFile(ready, '')
        while (!(await exists(release))) await new Promise((r) => setTimeout(r, 20))
      }, { command: 'node holder' })
      """.write(to: script, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = ["--import", "tsx", script.path, bookDir.path, ready.path, release.path]
    process.currentDirectoryURL = root
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let deadline = Date().addingTimeInterval(20)
    while !FileManager.default.fileExists(atPath: ready.path) {
      guard process.isRunning, Date() < deadline else {
        return XCTFail("the Node holder never took the lock")
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertThrowsError(try BookLock.acquire(bookDir: bookDir)) { error in
      let busy = error as? BookBusyError
      XCTAssertEqual(busy?.pid, process.processIdentifier)
      XCTAssertEqual(busy?.command, "node holder")
    }

    try Data().write(to: release)
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    // Node released it the way the native side does: nothing left behind.
    XCTAssertFalse(FileManager.default.fileExists(atPath: BookLock.lockPath(bookDir).path))
    try BookLock.acquire(bookDir: bookDir).release()
  }

  func testCommandLineProbeAndPattern() {
    let own = BookLock.processCommandLine(getpid())
    XCTAssertNotNil(own)
    XCTAssertTrue(own?.contains("xctest") == true || own?.contains("Tests") == true, own ?? "")

    XCTAssertTrue(BookLock.ownerLooksLive(nil))
    XCTAssertTrue(BookLock.ownerLooksLive("/usr/local/bin/node /x/kindle-export/dist/cli.js"))
    XCTAssertTrue(BookLock.ownerLooksLive("/Applications/Kindle Export.app/Contents/MacOS/x"))
    XCTAssertTrue(BookLock.ownerLooksLive(".build/debug/KindleExport"))
    XCTAssertTrue(BookLock.ownerLooksLive(".build/debug/kexport capture B00X --out out"))
    // The native command-line tool, as each of the ways it runs looks to ps.
    XCTAssertTrue(
      BookLock.ownerLooksLive("/Applications/Kindle Export.app/Contents/MacOS/kindle-export B00X"))
    XCTAssertTrue(BookLock.ownerLooksLive("/usr/local/bin/kindle-export list"))
    XCTAssertTrue(BookLock.ownerLooksLive(".build/release/kindle-export B00X"))
    XCTAssertFalse(BookLock.ownerLooksLive("/usr/bin/vim"))
  }
}
