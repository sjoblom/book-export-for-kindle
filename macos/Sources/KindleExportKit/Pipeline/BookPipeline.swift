import Foundation

/// What a pipeline run reports as it goes (pipeline.ts `PipelineEvent`).
public enum PipelineEvent: Equatable, Sendable {
  public enum Stage: String, Sendable {
    case capture
    case transcribe
    case export
  }

  /// Something worth saying.
  case info(String)
  /// Something wrong but survivable — the book still exports.
  case warn(String)
  /// A stage is starting work (not emitted when its output is reused).
  case stage(Stage)
  /// Screens captured so far and the book page reached; only `page` is
  /// comparable with `total` (content pages, unknown until the reader says).
  case captureProgress(captured: Int, page: Int?, total: Int?)
  case transcribeProgress(done: Int, total: Int)
}

/// The outcome of one book (pipeline.ts `BookResult`).
public struct BookResult: Sendable {
  public var asin: String
  /// Files written (or already present, for reused stages).
  public var outputs: [URL]
  /// How much of the book is on disk once the run finished — read from the
  /// files, not from which stages ran.
  public var completeness: BookCompleteness
  /// Pages this run tried to read and could not.
  public var failedPages: [FailedPage]
  public var duration: TimeInterval

  /// pipeline.ts `bookFellShort`: whether the book fell short of what the
  /// command promised. `capture` only promises the pages.
  public func fellShort(_ command: BookPipeline.Command = .all) -> Bool {
    if !failedPages.isEmpty { return true }
    return command == .capture ? completeness.captureStoppedEarly : !completeness.complete
  }
}

/// Runs one book through capture → transcribe → export, like pipeline.ts
/// `processBook`, under the book lock shared with the Node tool.
///
/// Capture needs the app's web view, so it is injected. Everything else —
/// Vision, KindleCore, the files — is here. An actor, so its `PipelineCore`
/// is only ever used from one context.
public actor BookPipeline {
  public enum Command: String, Sendable {
    /// Capture if needed, transcribe, export.
    case all
    case capture
    /// Transcribe what is captured (the CLI's `ocr`).
    case transcribe
    case export
  }

  public struct Options: Sendable {
    public var command: Command
    public var formats: [ExportFormat]
    /// Keep page images after every page has text.
    public var keepPages: Bool
    /// Capture again even if pages are on disk.
    public var forceCapture: Bool
    /// Re-read every page, discarding text from a previous run.
    public var forceOcr: Bool
    /// Vision recognition languages (BCP-47); `nil` for Vision's default.
    public var languages: [String]?
    /// Pages read in parallel.
    public var concurrency: Int

    public init(
      command: Command = .all, formats: [ExportFormat] = [.md], keepPages: Bool = false,
      forceCapture: Bool = false, forceOcr: Bool = false, languages: [String]? = nil,
      concurrency: Int = VisionOCR.defaultConcurrency
    ) {
      self.command = command
      self.formats = formats
      self.keepPages = keepPages
      self.forceCapture = forceCapture
      self.forceOcr = forceOcr
      self.languages = languages
      self.concurrency = concurrency
    }
  }

  /// Captures `asin` into `store.bookDir`: page images and a metadata.json
  /// rewritten after every screen. Provided by the app, which owns the web
  /// view. Progress is read back from metadata.json, as the Node pipeline does.
  public typealias Capture = @Sendable (_ asin: String, _ store: BookStore) async throws -> Void

  public typealias Emit = @Sendable (PipelineEvent) -> Void

  public enum PipelineError: LocalizedError, Equatable {
    case captureUnavailable
    case captureProducedNoPages
    case noCapturedPages
    case noTranscribedText

    public var errorDescription: String? {
      switch self {
      case .captureUnavailable: return "this book has not been captured yet"
      case .captureProducedNoPages: return "capture produced no page images"
      case .noCapturedPages: return "no captured pages — capture the book first"
      case .noTranscribedText: return "no transcribed text — read the pages first"
      }
    }
  }

  /// Failed pages listed individually before collapsing to a count.
  static let maxReportedFailures = 10
  /// How often metadata.json is read for capture progress.
  static let capturePollNanoseconds: UInt64 = 2_000_000_000

  public let outDir: URL
  private let capture: Capture?
  private let recognizer: PageRecognizer?
  private let makeCore: @Sendable () throws -> PipelineCore
  private let lockProbes: BookLock.Probes
  /// Who holds the book lock, as the next run's "busy" message names it
  /// ("app all", "kindle-export capture").
  private let ownerName: String
  private var core: PipelineCore?

  /// - Parameters:
  ///   - capture: `nil` when this pipeline never captures (pages must exist).
  ///   - recognizer: `nil` for Vision with the run's languages/concurrency.
  ///   - makeCore: KindleCore for the pipeline and each transcription.
  ///   - ownerName: names this program in the book lock.
  public init(
    outDir: URL, capture: Capture? = nil, recognizer: PageRecognizer? = nil,
    makeCore: @escaping @Sendable () throws -> PipelineCore = { try PipelineCore() },
    lockProbes: BookLock.Probes = .system, ownerName: String = "app"
  ) {
    self.outDir = outDir
    self.ownerName = ownerName
    self.capture = capture
    self.recognizer = recognizer
    self.makeCore = makeCore
    self.lockProbes = lockProbes
  }

  private func pipelineCore() throws -> PipelineCore {
    if let core { return core }
    let made = try makeCore()
    core = made
    return made
  }

  /// Process one book. Throws `BookBusyError` if another run holds it.
  public func process(asin: String, options: Options = Options(), emit: @escaping Emit = { _ in })
    async throws -> BookResult
  {
    let store = BookStore(outDir: outDir, asin: asin)
    return try await BookLock.withLock(
      bookDir: store.bookDir, command: "\(ownerName) \(options.command.rawValue)",
      probes: lockProbes
    ) {
      try await processLocked(store: store, options: options, emit: emit)
    }
  }

  private func processLocked(store: BookStore, options: Options, emit: @escaping Emit)
    async throws -> BookResult
  {
    let startedAt = Date()
    let core = try pipelineCore()

    // A run can reach the same conclusion twice; the reader needs it once.
    var said = Set<String>()
    let emitOnce: (PipelineEvent) -> Void = { event in
      if case .warn(let message) = event {
        if said.contains(message) { return }
        said.insert(message)
      }
      emit(event)
    }

    let metadata: BookMetadataFile?
    switch options.command {
    case .transcribe, .export:
      metadata = store.readMetadata()
    case .all, .capture:
      metadata = try await captureStage(
        store: store, options: options, core: core, emit: emitOnce, progress: emit)
    }
    guard let metadata, !metadata.pages.isEmpty else { throw PipelineError.noCapturedPages }

    var failedPages: [FailedPage] = []

    func finish(_ outputs: [URL]) throws -> BookResult {
      let completeness = try core.bookCompleteness(metadata: metadata, content: store.readContent())
      if options.command != .capture {
        for message in completeness.warnings { emitOnce(.warn(message)) }
      }
      return BookResult(
        asin: store.asin, outputs: outputs, completeness: completeness, failedPages: failedPages,
        duration: Date().timeIntervalSince(startedAt))
    }

    if options.command == .capture { return try finish([store.bookDir]) }

    let content: [ContentChunk]
    if options.command == .export {
      content = try core.selectReusableChunks(store.readContent(), metadata)
    } else {
      let transcribed = try await transcribeStage(
        store: store, metadata: metadata, options: options, core: core, emit: emitOnce,
        progress: emit)
      content = transcribed.content
      failedPages = transcribed.failedPages
    }
    guard !content.isEmpty else { throw PipelineError.noTranscribedText }

    if options.command == .transcribe { return try finish([store.contentURL]) }

    emitOnce(.stage(.export))
    let exporter = Exporter(store: store, core: core)
    var outputs: [URL] = []
    for format in options.formats {
      try Task.checkCancellation()
      outputs.append(try exporter.export(format, content: content))
    }
    return try finish(outputs)
  }

  // MARK: stages

  /// Say so when the pages on disk are only part of a book — a truncated
  /// capture otherwise exports cleanly and silently.
  private func reportIncompleteCapture(
    _ metadata: BookMetadataFile, core: PipelineCore, emit: (PipelineEvent) -> Void
  ) {
    // With no content every page is "missing", but those warnings are only
    // added when the capture itself is fine — so when it stopped early the
    // warnings are exactly the capture's.
    guard let completeness = try? core.bookCompleteness(metadata: metadata, content: nil),
      completeness.captureStoppedEarly
    else { return }
    for message in completeness.warnings { emit(.warn(message)) }
  }

  private func captureStage(
    store: BookStore, options: Options, core: PipelineCore, emit: (PipelineEvent) -> Void,
    progress: @escaping Emit
  ) async throws -> BookMetadataFile? {
    if !options.forceCapture, let existing = store.readMetadata(), !existing.pages.isEmpty {
      emit(.info("capture: reusing \(existing.pages.count) existing page images"))
      reportIncompleteCapture(existing, core: core, emit: emit)
      return existing
    }

    guard let capture else { throw PipelineError.captureUnavailable }

    emit(.stage(.capture))
    emit(.info("capture: opening Kindle reader"))

    // The capture rewrites metadata.json after every page, so progress is
    // read from disk rather than threaded through the capture code.
    let poll = Task.detached { [store] in
      var lastCaptured = -1
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: BookPipeline.capturePollNanoseconds)
        guard !Task.isCancelled, let partial = store.readMetadata() else { continue }
        let captured = partial.pages.count
        guard captured > lastCaptured else { continue }
        lastCaptured = captured
        let page = partial.pages.last?.page
        progress(
          .captureProgress(
            captured: captured, page: (page ?? 0) > 0 ? page : nil,
            total: partial.totalContentPages))
      }
    }
    defer { poll.cancel() }

    try await capture(store.asin, store)
    poll.cancel()

    guard let metadata = store.readMetadata(), !metadata.pages.isEmpty else {
      throw PipelineError.captureProducedNoPages
    }

    // The previous transcription was read from page images that no longer
    // exist; dropping it makes a forced re-capture re-export this capture.
    try store.invalidateContent()

    emit(.info("capture: \(metadata.pages.count) page images"))
    reportIncompleteCapture(metadata, core: core, emit: emit)

    // Amazon's render payloads are only useful during the capture itself.
    if let render = try? store.cleanRenderData(), render.freed > 0 {
      emit(.info("capture: freed \(formatBytes(render.freed)) of render data"))
    }

    return metadata
  }

  private func transcribeStage(
    store: BookStore, metadata: BookMetadataFile, options: Options, core: PipelineCore,
    emit: (PipelineEvent) -> Void, progress: @escaping Emit
  ) async throws -> Transcriber.Result {
    // Only text that belongs to the capture on disk counts: chunks left from
    // an earlier capture count to the same number and describe other pages.
    let existing = try core.selectReusableChunks(store.readContent(), metadata)
    if !options.forceOcr, !existing.isEmpty, existing.count >= metadata.pages.count {
      emit(.info("transcribe: reusing \(existing.count) chunks"))
      return Transcriber.Result(content: existing, failedPages: [])
    }

    emit(.stage(.transcribe))

    let transcriber = Transcriber(
      store: store, core: try makeCore(),
      ocr: recognizer
        ?? VisionOCR(languages: options.languages, maxConcurrent: options.concurrency))
    let result = try await transcriber.transcribe(
      options: Transcriber.Options(concurrency: options.concurrency, force: options.forceOcr),
      onProgress: { done, total in progress(.transcribeProgress(done: done, total: total)) })

    guard !result.content.isEmpty else { throw PipelineError.noTranscribedText }

    let failed = result.failedPages
    if !failed.isEmpty {
      // The book still exports, with holes the user has to know about.
      emit(.warn("\(failed.count) of \(metadata.pages.count) pages could not be read:"))
      for failure in failed.prefix(BookPipeline.maxReportedFailures) {
        emit(.warn("  page \(failure.page) (\(failure.error))"))
      }
      if failed.count > BookPipeline.maxReportedFailures {
        emit(.warn("  ...and \(failed.count - BookPipeline.maxReportedFailures) more"))
      }
      emit(.warn("the export below is missing those pages — re-run to retry just them"))
    }

    // Page images are only the input to this step. Once every page has text
    // they are dead weight. The check is coverage, not "no failures this run".
    let covered = try core.bookCompleteness(
      metadata: metadata,
      content: ContentStore(captureId: metadata.captureId, chunks: result.content)
    ).missingPages.isEmpty

    if !options.keepPages, covered {
      let pages = try store.cleanPageImages()
      if pages.freed > 0 {
        emit(.info("transcribe: freed \(formatBytes(pages.freed)) of page images"))
      }
    }

    return result
  }
}
