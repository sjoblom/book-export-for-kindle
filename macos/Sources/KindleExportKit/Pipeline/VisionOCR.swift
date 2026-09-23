import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads one page image into lines of text. `VisionOCR` is the real one; the
/// transcriber takes any, so its retry rules can be tested without Vision.
public protocol PageRecognizer: Sendable {
  /// - Parameter attempt: 0 for the first try at this page, then 1, 2, …
  func recognize(imageAt url: URL, attempt: Int) async throws -> [OcrLine]
}

/// The image could not be opened or decoded. Retrying cannot help, so the
/// transcriber fails the page at once (ocr-engine.ts `OcrPageUnreadableError`).
public struct PageUnreadableError: LocalizedError, Equatable {
  public let path: String
  public init(path: String) { self.path = path }
  public var errorDescription: String? { "page image is missing or unreadable: \(path)" }
}

/// Apple's Vision text recognition, in process (native/macos-ocr/main.swift
/// without the stdin/stdout worker around it).
///
/// Answers are one entry per rendered line with the box it occupies, in
/// pixels from the top-left of the image: where lines sit is the only
/// evidence left of where the paragraphs were, and KindleCore rebuilds them.
public final class VisionOCR: PageRecognizer, @unchecked Sendable {
  /// BCP-47 tags, e.g. ["en-US"]; `nil` means Vision's own default.
  public let languages: [String]?
  /// Let Vision resolve ambiguous glyphs against a dictionary. On by default:
  /// measured over a real 126-page book it changed 62 pages and touched a
  /// digit exactly once.
  public let usesLanguageCorrection: Bool
  public let maxConcurrent: Int

  private let queue = DispatchQueue(
    label: "kindle-export.vision-ocr", qos: .userInitiated, attributes: .concurrent)
  private let slots: AsyncSemaphore

  /// Vision parallelises internally and needs threads of its own; flooding
  /// it with a whole book at once deadlocks it. The Node worker's cap.
  public static var defaultConcurrency: Int {
    max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
  }

  public init(
    languages: [String]? = nil, usesLanguageCorrection: Bool = true,
    maxConcurrent: Int = VisionOCR.defaultConcurrency
  ) {
    self.languages = languages
    self.usesLanguageCorrection = usesLanguageCorrection
    self.maxConcurrent = max(1, maxConcurrent)
    slots = AsyncSemaphore(self.maxConcurrent)
  }

  public func recognize(imageAt url: URL, attempt _: Int = 0) async throws -> [OcrLine] {
    try await slots.acquire()
    defer { Task { await slots.release() } }
    try Task.checkCancellation()

    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [languages, usesLanguageCorrection] in
        continuation.resume(
          with: Result {
            try VisionOCR.recognizeSync(
              url: url, languages: languages, correct: usesLanguageCorrection)
          })
      }
    }
  }

  /// Synchronous recognition of one image. Blocks; call off the main thread.
  public static func recognizeSync(url: URL, languages: [String]?, correct: Bool) throws
    -> [OcrLine]
  {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw PageUnreadableError(path: url.path)
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = correct
    if let languages, !languages.isEmpty {
      request.recognitionLanguages = languages
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])

    guard let observations = request.results else { return [] }

    // Observations arrive in reading order, one line each; keep that order.
    let width = Double(cgImage.width)
    let height = Double(cgImage.height)

    return observations.compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      // Vision's boxes are normalised with the origin at the bottom left.
      let box = observation.boundingBox
      return OcrLine(
        text: text,
        left: round2(box.minX * width),
        top: round2((1 - box.maxY) * height),
        width: round2(box.width * width),
        height: round2(box.height * height))
    }
  }

  /// Sub-pixel precision means nothing here and would triple a page's JSON.
  static func round2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
  }
}

/// A counting semaphore for async code: waiting suspends instead of blocking
/// a thread, so a queue of pages costs nothing while it waits.
actor AsyncSemaphore {
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(_ count: Int) { available = count }

  func acquire() async throws {
    if available > 0 {
      available -= 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      available += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}
