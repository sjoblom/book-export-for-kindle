import Foundation

/// Page image blobs the reader turned into object URLs, waiting for the one
/// that becomes the main image's `src`.
///
/// A port of `capturedBlobs` / `evictStaleBlobs` / `takeCapturedBlob` in
/// extract-kindle-book.ts. Every image blob lands here, but only the one shown
/// is ever consumed; the rest (pages rendered while walking to a target page,
/// neighbours Kindle prefetches) would pile up for the whole capture, so
/// entries are aged out.
///
/// Eviction is by age rather than by position relative to the consumed blob:
/// blobs arrive in the order their bytes finish copying, not the order Kindle
/// created them, and a prefetched neighbour can be rendered before the page
/// about to be shown. A blob that has sat through several consumptions without
/// becoming `src` belongs to a page behind us — a revisit gets a fresh URL.
public final class BlobStore {
  public struct Blob {
    public let type: String
    public let data: Data
    /// How many blobs had been consumed when this one arrived.
    public let consumedAtArrival: Int
  }

  public static let defaultMaxAgeInConsumptions = 8
  public static let defaultMaxCount = 64

  /// Consumptions a blob may sit through before it is dropped.
  public let maxAgeInConsumptions: Int
  /// Backstop for long stretches with no consumption at all (walking hundreds
  /// of pages to the start of the book): the oldest entries go first.
  public let maxCount: Int

  private var blobs: [String: Blob] = [:]
  /// Insertion order, oldest first — Swift dictionaries have none.
  private var order: [String] = []
  public private(set) var consumedCount = 0

  public init(
    maxAgeInConsumptions: Int = BlobStore.defaultMaxAgeInConsumptions,
    maxCount: Int = BlobStore.defaultMaxCount
  ) {
    self.maxAgeInConsumptions = maxAgeInConsumptions
    self.maxCount = maxCount
  }

  public var count: Int { blobs.count }
  public var urls: [String] { order }
  public func contains(_ url: String) -> Bool { blobs[url] != nil }

  public func insert(url: String, type: String, data: Data) {
    // A JS Map `set` on an existing key keeps its original position.
    if blobs[url] == nil { order.append(url) }
    blobs[url] = Blob(type: type, data: data, consumedAtArrival: consumedCount)
    evictStale()
  }

  /// Remove and return the blob for `url`, counting it as consumed.
  public func take(_ url: String) -> Blob? {
    guard let blob = blobs.removeValue(forKey: url) else { return nil }
    order.removeAll { $0 == url }
    consumedCount += 1
    evictStale()
    return blob
  }

  /// Object URLs die with the document that made them: after a reload nothing
  /// held here can ever be `src` again.
  public func removeAll() {
    blobs.removeAll()
    order.removeAll()
  }

  func evictStale() {
    order.removeAll { url in
      guard let blob = blobs[url] else { return true }
      if consumedCount - blob.consumedAtArrival > maxAgeInConsumptions {
        blobs.removeValue(forKey: url)
        return true
      }
      return false
    }

    while blobs.count > maxCount, let oldest = order.first {
      order.removeFirst()
      blobs.removeValue(forKey: oldest)
    }
  }
}
