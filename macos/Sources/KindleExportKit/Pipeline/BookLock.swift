import Darwin
import Foundation

/// One run per book at a time, shared with the Node tool (src/book-lock.ts).
///
/// The lock is a directory, `<bookDir>/.lock`, holding exactly one owner file
/// named for one acquisition: `owner-<pid>-<token>.json`. Every mutation is a
/// step the filesystem refuses if things changed since we looked:
///
/// - take: `rename()` a staging directory that already holds our owner file
///   onto `.lock` — succeeds only if `.lock` is absent or empty;
/// - recover a stale owner: `unlink()` the owner file we read, by its unique
///   name, then `rmdir()` `.lock`, which fails unless it is empty;
/// - release: the same unlink-then-rmdir on our own file.
///
/// An owner is stale when its pid is dead, or alive but running something
/// that is plainly not book-export (pids get recycled). Anything we can't
/// tell apart is treated as live: refusing is recoverable, two writers aren't.
public enum BookLock {
  public static let directoryName = ".lock"
  static let acquireAttempts = 8

  /// How a lock owner's process is judged; injectable for tests.
  public struct Probes: Sendable {
    public var isAlive: @Sendable (Int32) -> Bool
    public var commandLine: @Sendable (Int32) -> String?

    public init(
      isAlive: @escaping @Sendable (Int32) -> Bool,
      commandLine: @escaping @Sendable (Int32) -> String?
    ) {
      self.isAlive = isAlive
      self.commandLine = commandLine
    }

    public static let system = Probes(
      isAlive: { BookLock.isProcessAlive($0) }, commandLine: { BookLock.processCommandLine($0) })
  }

  struct Owner: Codable, Equatable {
    var pid: Int32
    var token: String
    var startedAt: String
    var command: String?

    var fileName: String { BookLock.ownerFileName(pid: pid, token: token) }

    var json: Data {
      OrderedJSON.object([
        ("pid", .number(Double(pid))),
        ("token", .string(token)),
        ("startedAt", .string(startedAt)),
        ("command", command.map { .string($0) }),
      ]).data(pretty: true)
    }
  }

  public static func lockPath(_ bookDir: URL) -> URL {
    bookDir.appendingPathComponent(directoryName, isDirectory: true)
  }

  /// book-lock.ts `ownerFileName`.
  public static func ownerFileName(pid: Int32, token: String) -> String {
    "owner-\(pid)-\(token).json"
  }

  /// book-lock.ts `ownerLooksLive`, the same pattern: every program that
  /// takes this lock — Node, the app (`Book Export for Kindle`, or `KindleExport`
  /// outside a bundle), the native `book-export` tool (from inside the
  /// bundle, its PATH link or `.build/`) and the `kexport` developer tool it
  /// replaced, which older checkouts may still run. A live owner that
  /// matches none of them is a recycled pid, so leaving one out would let its
  /// lock be taken from under it.
  public static func ownerLooksLive(_ commandLine: String?) -> Bool {
    guard let commandLine else { return true }
    return commandLine.range(
      of: #"\b(node|kindle-export|book-export|tsx|Kindle Export|Book Export for Kindle|KindleExport|kexport)\b"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Take the book's lock, run `body`, and release it — including when
  /// `body` throws. A live owner raises `BookBusyError`.
  public static func withLock<T>(
    bookDir: URL, command: String? = nil, probes: Probes = .system,
    _ body: () async throws -> T
  ) async throws -> T {
    let handle = try acquire(bookDir: bookDir, command: command, probes: probes)
    defer { handle.release() }
    return try await body()
  }

  /// A held lock. `release()` is idempotent.
  public final class Handle {
    let bookDir: URL
    let owner: Owner
    private var released = false

    init(bookDir: URL, owner: Owner) {
      self.bookDir = bookDir
      self.owner = owner
    }

    public var ownerFileName: String { owner.fileName }

    public func release() {
      guard !released else { return }
      released = true
      let lockDir = BookLock.lockPath(bookDir)
      // Our own file by its unique name, then the directory only if that left
      // it empty. Neither step can touch a successor's lock.
      unlink(lockDir.appendingPathComponent(owner.fileName).path)
      rmdir(lockDir.path)
    }

    deinit { release() }
  }

  public static func acquire(
    bookDir: URL, command: String? = nil, probes: Probes = .system
  ) throws -> Handle {
    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let owner = Owner(
      pid: getpid(), token: UUID().uuidString.lowercased(),
      startedAt: formatter.string(from: Date()), command: command)

    let lockDir = lockPath(bookDir)
    var lastSeen: Owner?

    for _ in 0..<acquireAttempts {
      if try tryTake(bookDir: bookDir, owner: owner) {
        return Handle(bookDir: bookDir, owner: owner)
      }

      switch try inspect(lockDir) {
      case .missing:
        continue
      case .file(let seen):
        // A lock from an earlier version of the Node module, a plain file.
        try judge(seen, bookDir: bookDir, probes: probes)
        unlink(lockDir.path)
        continue
      case .empty:
        // An owner mid-release or mid-recovery. rmdir() only succeeds while
        // it is still empty.
        rmdir(lockDir.path)
        continue
      case .owned(let name, let seen):
        try judge(seen, bookDir: bookDir, probes: probes)
        lastSeen = seen ?? lastSeen
        // Stale: remove the owner file we read, by the name we read. Gone
        // already means someone else recovered it and may own it now.
        if unlink(lockDir.appendingPathComponent(name).path) != 0 {
          if errno == ENOENT { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        rmdir(lockDir.path)
      }
    }

    // Every pass lost a race to another contender: that is a busy book.
    throw BookBusyError(pid: lastSeen?.pid ?? 0, bookDir: bookDir, command: lastSeen?.command)
  }

  /// Throw if `owner` is a live book-export run; return if it is stale.
  private static func judge(_ owner: Owner?, bookDir: URL, probes: Probes) throws {
    guard let owner else { return }
    if probes.isAlive(owner.pid), ownerLooksLive(probes.commandLine(owner.pid)) {
      throw BookBusyError(pid: owner.pid, bookDir: bookDir, command: owner.command)
    }
  }

  private static func tryTake(bookDir: URL, owner: Owner) throws -> Bool {
    let lockDir = lockPath(bookDir)
    let staging = bookDir.appendingPathComponent("\(directoryName).staging.\(owner.token)")

    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    try owner.json.write(to: staging.appendingPathComponent(owner.fileName))

    if rename(staging.path, lockDir.path) == 0 { return true }
    let code = errno
    try? FileManager.default.removeItem(at: staging)
    // ENOTEMPTY / EEXIST: a populated lock is there. ENOTDIR: an old-style
    // lock file. All mean "held", and inspect() sorts them out.
    guard code == ENOTEMPTY || code == EEXIST || code == ENOTDIR else {
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return false
  }

  private enum Inspection {
    case missing
    case empty
    case file(Owner?)
    case owned(name: String, owner: Owner?)
  }

  private static func inspect(_ lockDir: URL) throws -> Inspection {
    guard let dir = opendir(lockDir.path) else {
      if errno == ENOENT { return .missing }
      if errno == ENOTDIR { return .file(readOwner(lockDir)) }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var entries: [String] = []
    while let entry = readdir(dir) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." { entries.append(name) }
    }
    closedir(dir)

    if entries.isEmpty { return .empty }
    // Exactly one owner file is the only shape we write; anything else is
    // treated as that entry being the owner (an unreadable one is stale).
    let name = entries.first { $0.hasPrefix("owner-") } ?? entries[0]
    return .owned(name: name, owner: readOwner(lockDir.appendingPathComponent(name)))
  }

  private static func readOwner(_ file: URL) -> Owner? {
    guard let data = try? Data(contentsOf: file),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pidNumber = object["pid"] as? NSNumber,
      CFGetTypeID(pidNumber) != CFBooleanGetTypeID(),
      pidNumber.doubleValue > 0, pidNumber.doubleValue <= Double(Int32.max)
    else { return nil }
    return Owner(
      pid: pidNumber.int32Value,
      token: object["token"] as? String ?? "",
      startedAt: object["startedAt"] as? String ?? "",
      command: object["command"] as? String)
  }

  // MARK: process probes

  /// `process.kill(pid, 0)` as Node does it: only a successful signal counts,
  /// so EPERM (someone else's process) reads as not alive, as on the Node side.
  public static func isProcessAlive(_ pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
  }

  /// The process's command line, or `nil` when it can't be read. Arguments
  /// come from `sysctl(KERN_PROCARGS2)`, joined by spaces like `ps -o command=`.
  public static func processCommandLine(_ pid: Int32) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argmax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: Int(argmax))
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    size = buffer.count
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }

    // Layout: argc (Int32), the executable path, NUL padding, then argc
    // NUL-terminated arguments (followed by the environment, ignored).
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var offset = MemoryLayout<Int32>.size
    while offset < size, buffer[offset] != 0 { offset += 1 }  // exec path
    while offset < size, buffer[offset] == 0 { offset += 1 }  // padding

    var args: [String] = []
    while args.count < argc, offset < size {
      let start = offset
      while offset < size, buffer[offset] != 0 { offset += 1 }
      args.append(String(decoding: buffer[start..<offset], as: UTF8.self))
      offset += 1
    }
    let line = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
  }
}

/// book-lock.ts `BookBusyError`: another run holds this book.
public struct BookBusyError: LocalizedError, Equatable {
  public static let code = "BOOK_BUSY"
  public let pid: Int32
  public let bookDir: URL
  public let command: String?

  public var errorDescription: String? {
    "another book-export\(command.map { " (\($0))" } ?? "") is working on "
      + "this book\(pid != 0 ? " (pid \(pid))" : ""); wait for it to finish and try again"
  }
}
