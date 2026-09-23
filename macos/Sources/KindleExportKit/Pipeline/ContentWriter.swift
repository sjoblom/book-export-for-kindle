import Foundation

/// A serialized, debounced, atomic writer for one book's `content.json`
/// (content-store.ts `createContentWriter`).
///
/// Pages are read in parallel and each finished one comes through here, so an
/// interrupted run keeps what it already read. A save happens once 16 pages
/// have finished since the last one, or 250 ms after the first unsaved page,
/// whichever is sooner. Saves run on this actor and are synchronous within
/// it, so two can never interleave.
public actor ContentWriter {
  /// Longest a finished page waits before it is on disk.
  public static let debounceNanoseconds: UInt64 = 250_000_000
  /// Completions that force a save regardless of the debounce.
  public static let writeEveryCompletions = 16

  private let store: BookStore
  private let captureId: String?
  private let debounceNanoseconds: UInt64
  private var byIndex: [Int: ContentChunk]
  // The first flush always writes, so even a run with nothing to do leaves the
  // file in the current shape rather than an older one.
  private var dirty = true
  private var sinceWrite = 0
  private var timer: Task<Void, Never>?
  private var timerGeneration = 0
  private var failure: Error?

  /// Saves that reached disk, for tests.
  public private(set) var writes = 0

  public init(
    store: BookStore, captureId: String?, chunks initial: [ContentChunk] = [],
    debounceNanoseconds: UInt64 = ContentWriter.debounceNanoseconds
  ) {
    self.store = store
    self.captureId = captureId
    self.debounceNanoseconds = debounceNanoseconds
    var byIndex: [Int: ContentChunk] = [:]
    for chunk in initial { byIndex[chunk.index] = chunk }
    self.byIndex = byIndex
  }

  /// Record a finished page. Saving it is coalesced, never interleaved.
  public func add(_ chunk: ContentChunk) {
    byIndex[chunk.index] = chunk
    dirty = true
    sinceWrite += 1

    // A burst of fast pages would otherwise sit behind the debounce
    // indefinitely, each new one pushing the save further out.
    if sinceWrite >= ContentWriter.writeEveryCompletions {
      cancelTimer()
      save()
      return
    }
    schedule()
  }

  /// Everything recorded so far, in page order.
  public func chunks() -> [ContentChunk] {
    byIndex.values.sorted { $0.index < $1.index }
  }

  /// Save everything recorded so far. Throws if that save failed.
  public func flush() throws {
    cancelTimer()
    failure = nil
    save()
    if let failure { throw failure }
  }

  private func save() {
    guard dirty else { return }
    dirty = false
    sinceWrite = 0
    do {
      try store.writeContent(ContentStore(captureId: captureId, chunks: chunks()))
      writes += 1
    } catch {
      // Losing an intermediate save is survivable — the pages are still in
      // memory for the next one — so the run continues and `flush` reports it.
      dirty = true
      failure = error
    }
  }

  private func schedule() {
    guard timer == nil else { return }
    let delay = debounceNanoseconds
    timerGeneration += 1
    let generation = timerGeneration
    timer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      guard !Task.isCancelled else { return }
      await self?.timerFired(generation)
    }
  }

  private func timerFired(_ generation: Int) {
    // A timer cancelled after its sleep ended still gets here; only the
    // current one may save and clear the slot.
    guard generation == timerGeneration, timer != nil else { return }
    timer = nil
    save()
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
  }
}
