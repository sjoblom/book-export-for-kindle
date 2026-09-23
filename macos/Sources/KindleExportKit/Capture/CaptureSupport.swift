import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small pure pieces of the capture, kept out of the browser-driving code so
/// they can be tested.
public enum CaptureSupport {
  /// Where the page images go inside a book directory (utils.ts
  /// `PAGE_IMAGES_DIR`).
  public static let pageImagesDir = "pages"

  /// The digits page image names are padded to: `${totalNumContentPages * 2}`
  /// `.length`, as extractBook computes it.
  public static func pageNumberPadding(totalContentPages: Int) -> Int {
    String(totalContentPages * 2).count
  }

  /// `pages/NNN-PPP.png`, relative to the book directory — JS `padStart`
  /// semantics, so a negative page pads the same way it does in Node.
  public static func screenshotPath(index: Int, page: Int, padding: Int) -> String {
    pageImagesDir + "/" + padStart(String(index), padding) + "-"
      + padStart(String(page), padding) + ".png"
  }

  static func padStart(_ s: String, _ length: Int) -> String {
    s.count >= length ? s : String(repeating: "0", count: length - s.count) + s
  }

  /// SHA-256 hex, used to recognise screens seen again after a recovery.
  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A CSS-pixel point in the web view's viewport → the window's base
  /// coordinate space, which is what `NSEvent.mouseEvent(location:)` takes.
  ///
  /// - Parameters:
  ///   - webViewFrameInWindow: the web view's bounds converted to window
  ///     coordinates (`webView.convert(webView.bounds, to: nil)`); window
  ///     coordinates have their origin bottom-left, CSS top-left.
  ///   - zoom: CSS px → points (`pageZoom × magnification`, 1 by default).
  public static func windowPoint(
    css: CGPoint, webViewFrameInWindow frame: CGRect, zoom: CGFloat = 1
  ) -> CGPoint {
    CGPoint(x: frame.minX + css.x * zoom, y: frame.maxY - css.y * zoom)
  }

  public struct ImageError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
  }

  /// The reader renders at device scale 2; the stored page images are 1×
  /// CSS pixels, as sharp's `resize(width / 2, height / 2)` makes them in
  /// Node. Always PNG.
  public static func downscaledPNG(_ data: Data, factor: Int = 2) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw ImageError(message: "page image could not be decoded") }

    let width = max(1, image.width / factor)
    let height = max(1, image.height / factor)

    // Keep grey pages grey (smaller files); everything else becomes RGB(A).
    let isGray = image.colorSpace?.model == .monochrome
    let hasAlpha: Bool = {
      switch image.alphaInfo {
      case .none, .noneSkipFirst, .noneSkipLast: return false
      default: return true
      }
    }()
    let colorSpace: CGColorSpace
    let bitmapInfo: UInt32
    if isGray, !hasAlpha {
      colorSpace = CGColorSpaceCreateDeviceGray()
      bitmapInfo = CGImageAlphaInfo.none.rawValue
    } else {
      colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
      bitmapInfo =
        hasAlpha
        ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    }

    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: bitmapInfo)
    else { throw ImageError(message: "could not create a \(width)×\(height) bitmap") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else {
      throw ImageError(message: "could not downscale the page image")
    }

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { throw ImageError(message: "could not create a PNG encoder") }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ImageError(message: "could not encode the page image as PNG")
    }
    return output as Data
  }
}
