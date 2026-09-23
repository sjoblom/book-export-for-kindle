import Foundation

/// Reads a book's captured page images into `content.json`
/// (src/transcribe-book-content.ts `transcribeBook`).
///
/// Pages already transcribed from *this* capture are kept, so a re-run reads
/// only what is missing. Each finished page is saved as it lands (debounced,
/// atomic), so an interrupted run keeps its work.
///
/// Vision runs concurrently; everything touching KindleCore happens on this
/// actor, which owns its own `PipelineCore` because a JSContext must not be
/// used from two threads at once.
public actor Transcriber {
  public struct Options: Sendable {
    /// Pages read in parallel.
    public var concurrency: Int
    /// Attempts per page before giving up on it.
    public var maxRetries: Int
    /// Re-read every page, discarding text from a previous run.
    public var force: Bool
    /// Wait before retry number `n` (1-based), in nanoseconds.
    public var retryDelay: @Sendable (Int) -> UInt64
    /// Debounce for the content writer, in nanoseconds.
    public var saveDebounce: UInt64

    public init(
      concurrency: Int = VisionOCR.defaultConcurrency,
      maxRetries: Int = Transcriber.defaultMaxRetries,
      force: Bool = false,
      retryDelay: @escaping @Sendable (Int) -> UInt64 = Transcriber.backoff,
      saveDebounce: UInt64 = ContentWriter.debounceNanoseconds
    ) {
      self.concurrency = concurrency
      self.maxRetries = maxRetries
      self.force = force
      self.retryDelay = retryDelay
      self.saveDebounce = saveDebounce
    }
  }

  public struct Result: Sendable {
    public var content: [ContentChunk]
    /// Pages that could not be read. Their text is absent from `content`, so
    /// callers must surface this rather than treat the result as complete.
    public var failedPages: [FailedPage]
  }

  public static let defaultMaxRetries = 20
  /// Attempts at an empty read before accepting the page really is blank.
  public static let emptyResponseRetries = 3

  /// `min(2000, 200 * 2^n)` ms, as the Node transcriber waits.
  public static let backoff: @Sendable (Int) -> UInt64 = { retries in
    let ms = min(2000.0, 200.0 * pow(2.0, Double(retries)))
    return UInt64(ms * 1_000_000)
  }

  private let store: BookStore
  private let core: PipelineCore
  private let ocr: PageRecognizer

  /// - Parameter core: used only from this actor; give it one of its own.
  public init(store: BookStore, core: PipelineCore, ocr: PageRecognizer) {
    self.store = store
    self.core = core
    self.ocr = ocr
  }

  public enum TranscribeError: LocalizedError, Equatable {
    case noPages
    case missingToc
    /// The page images were removed (they are once a book is fully read), so
    /// only a new capture can bring them back.
    case pageImagesGone(asin: String)

    public var errorDescription: String? {
      switch self {
      case .noPages: return "no page screenshots found"
      case .missingToc: return "invalid book metadata: missing toc"
      case .pageImagesGone:
        return "The page images for this book are gone — they are removed once a book "
          + "has been read. Capture the book again to fetch them."
      }
    }
  }

  public func transcribe(
    options: Options = Options(),
    onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
  ) async throws -> Result {
    guard let metadata = store.readMetadata(), !metadata.pages.isEmpty else {
      throw TranscribeError.noPages
    }
    guard !metadata.toc.isEmpty else { throw TranscribeError.missingToc }

    let existing =
      options.force ? [] : try core.selectReusableChunks(store.readContent(), metadata)
    let done = Set(existing.map(\.index))

    let writer = ContentWriter(
      store: store, captureId: metadata.captureId, chunks: existing,
      debounceNanoseconds: options.saveDebounce)

    let pending = metadata.pages.filter { !done.contains($0.index) }
    // Page images are cleaned up once a book is fully transcribed, so a
    // missing one usually means "already done and tidied".
    if let first = pending.first,
      !FileManager.default.fileExists(atPath: store.resolveScreenshotPath(first.screenshot).path)
    {
      throw TranscribeError.pageImagesGone(asin: store.asin)
    }

    let labels = try core.tocLabelsForChunks(metadata, pending.map { ($0.index, $0.page) })

    var failedPages: [FailedPage] = []
    var completed = 0
    let total = pending.count

    do {
      try await withThrowingTaskGroup(of: PageOutcome.self) { group in
        var next = 0
        func startNext() {
          guard next < pending.count else { return }
          let page = pending[next]
          let label = labels.indices.contains(next) ? labels[next] : nil
          next += 1
          group.addTask { try await self.read(page, tocLabel: label, options: options) }
        }

        for _ in 0..<max(1, options.concurrency) { startNext() }

        while let outcome = try await group.next() {
          switch outcome {
          case .read(let chunk):
            await writer.add(chunk)
          case .failed(let failure):
            failedPages.append(failure)
          }
          completed += 1
          onProgress?(completed, total)
          startNext()
        }
      }
    } catch {
      // Keep what was read before the run stopped.
      try? await writer.flush()
      throw error
    }

    // The last pages are still inside the save debounce; this makes the file
    // on disk the whole book rather than nearly it.
    try await writer.flush()

    return Result(
      content: await writer.chunks(),
      failedPages: failedPages.sorted { $0.index < $1.index })
  }

  private enum PageOutcome: Sendable {
    case read(ContentChunk)
    case failed(FailedPage)
  }

  /// One page, with the Node transcriber's retry rules. Runs off the actor
  /// except for the KindleCore calls.
  private nonisolated func read(
    _ page: BookMetadataFile.Page, tocLabel: String?, options: Options
  ) async throws -> PageOutcome {
    let imageURL = store.resolveScreenshotPath(page.screenshot)
    var retries = 0

    do {
      while true {
        try Task.checkCancellation()
        let attempt = retries
        let lines: [OcrLine]
        do {
          lines = try await ocr.recognize(imageAt: imageURL, attempt: attempt)
        } catch let error as PageUnreadableError {
          throw error
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // A missing image fails its page at once, whatever tripped over it.
          if !FileManager.default.isReadableFile(atPath: imageURL.path) {
            throw PageUnreadableError(path: imageURL.path)
          }
          retries += 1
          if retries >= options.maxRetries { throw error }
          try await Task.sleep(nanoseconds: options.retryDelay(retries))
          continue
        }

        // Judged before the TOC label comes off: a chapter-opening page that
        // is nothing but its heading is a real read, not an empty response.
        let hasText = try await shape(lines, tocLabel: nil) != ""
        retries += 1

        // Nothing came back: retry a couple of times, then accept the page is
        // blank — blank pages are ordinary, and failing them would mark the
        // book permanently incomplete.
        if !hasText, retries < min(Transcriber.emptyResponseRetries, options.maxRetries) {
          try await Task.sleep(nanoseconds: options.retryDelay(retries))
          continue
        }

        let text = try await shape(lines, tocLabel: tocLabel)
        return .read(
          ContentChunk(
            index: page.index, page: page.page, text: text, screenshot: page.screenshot,
            lines: lines.isEmpty ? nil : lines))
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failed(
        FailedPage(
          index: page.index, page: page.page, screenshot: page.screenshot,
          error: error.localizedDescription))
    }
  }

  private func shape(_ lines: [OcrLine], tocLabel: String?) throws -> String {
    try core.pageTextFromLines(lines, tocLabel: tocLabel)
  }
}
