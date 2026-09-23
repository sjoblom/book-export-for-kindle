import CoreGraphics
import CoreText
import Foundation

/// Lays out a `PdfBook` (KindleCore.pdfDocument) as a paginated PDF with
/// CoreText: a title page, then each section on a new page under a centred
/// heading sized by depth, with an outline entry per section.
///
/// Pure CoreGraphics/CoreText, so it runs off the main thread and needs no
/// web view.
public struct PdfRenderer {
  public enum Paper: Sendable {
    case letter
    case a4

    var size: CGSize {
      switch self {
      case .letter: return CGSize(width: 612, height: 792)
      case .a4: return CGSize(width: 595.28, height: 841.89)
      }
    }
  }

  public var paper: Paper = .letter
  public var margin: CGFloat = 72
  public var bodyFont = "Georgia"
  public var boldFont = "Georgia-Bold"
  public var bodySize: CGFloat = 12
  /// Section title sizes by TOC depth; deeper sections use the last one.
  public var headingSizes: [CGFloat] = [20, 16, 14]

  public init() {}

  public enum RenderError: LocalizedError {
    case cannotCreate(String)
    public var errorDescription: String? {
      switch self {
      case .cannotCreate(let path): return "could not create a PDF at \(path)"
      }
    }
  }

  /// Render `book` to `url` (replaced atomically). Returns the page count.
  @discardableResult
  public func render(_ book: PdfBook, to url: URL) throws -> Int {
    // Drawn aside and renamed, so a failed export never leaves half a PDF
    // under the real name.
    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(nextTempId()).tmp")
    do {
      let pages = try draw(book, to: temp)
      if rename(temp.path, url.path) != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return pages
    } catch {
      try? FileManager.default.removeItem(at: temp)
      throw error
    }
  }

  // MARK: drawing

  /// Draws every page and the outline; returns the page count.
  private func draw(_ book: PdfBook, to url: URL) throws -> Int {
    var mediaBox = CGRect(origin: .zero, size: paper.size)
    let info: [CFString: Any] = [
      kCGPDFContextTitle: book.title,
      kCGPDFContextAuthor: book.authors.joined(separator: ", "),
      kCGPDFContextCreator: "Book Export for Kindle",
    ]
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
      throw RenderError.cannotCreate(url.path)
    }

    var pageIndex = 0
    let content = mediaBox.insetBy(dx: margin, dy: margin)

    // Title page: title and byline, centred on the page.
    context.beginPDFPage(nil)
    let titlePage = NSMutableAttributedString()
    titlePage.append(
      text(book.title, font: boldFont, size: 36, style: paragraph(.center, after: 24)))
    if !book.authors.isEmpty {
      titlePage.append(
        text(
          "\nBy " + book.authors.joined(separator: ", "), font: bodyFont, size: 18,
          style: paragraph(.center)))
    }
    let titleSetter = CTFramesetterCreateWithAttributedString(titlePage)
    let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
      titleSetter, CFRange(location: 0, length: 0), nil,
      CGSize(width: content.width, height: content.height), nil)
    let titleHeight = min(content.height, ceil(fitted.height))
    let titleRect = CGRect(
      x: content.minX, y: content.midY - titleHeight / 2, width: content.width,
      height: titleHeight)
    CTFrameDraw(
      CTFramesetterCreateFrame(
        titleSetter, CFRange(location: 0, length: 0), CGPath(rect: titleRect, transform: nil),
        nil), context)
    context.endPDFPage()
    pageIndex += 1

    // Sections, each from a new page.
    var starts: [Int] = []
    for section in book.sections {
      starts.append(pageIndex)
      let body = sectionText(section)
      let setter = CTFramesetterCreateWithAttributedString(body)
      var location = 0
      repeat {
        context.beginPDFPage(nil)
        let frame = CTFramesetterCreateFrame(
          setter, CFRange(location: location, length: 0), CGPath(rect: content, transform: nil),
          nil)
        CTFrameDraw(frame, context)
        drawPageNumber(pageIndex + 1, in: context, box: mediaBox)
        context.endPDFPage()
        pageIndex += 1

        let visible = CTFrameGetVisibleStringRange(frame)
        // Nothing fit (a glyph taller than the page): stop rather than loop.
        if visible.length <= 0 { break }
        location = visible.location + visible.length
      } while location < body.length
    }

    // CoreGraphics writes the outline itself. (PDFKit's `outlineRoot` is not
    // saved by `PDFDocument.write` on this OS, which the tests caught.)
    CGPDFContextSetOutline(context, outline(book, sectionStarts: starts) as CFDictionary)
    context.closePDF()
    return pageIndex
  }

  private func sectionText(_ section: PdfBook.Section) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let depth = min(max(section.depth, 0), headingSizes.count - 1)
    result.append(
      text(
        section.label, font: boldFont, size: headingSizes[depth],
        style: paragraph(.center, after: 28)))

    // One paragraph per line of the formatted text, as pdfkit laid it out;
    // blank lines between paragraphs become paragraph spacing.
    let paragraphs = section.text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    if !paragraphs.isEmpty {
      result.append(
        text(
          "\n" + paragraphs.joined(separator: "\n"), font: bodyFont, size: bodySize,
          style: paragraph(.natural, firstIndent: 20, after: 8, lineSpacing: 4)))
    }
    return result
  }

  private func drawPageNumber(_ number: Int, in context: CGContext, box: CGRect) {
    let line = CTLineCreateWithAttributedString(
      text("\(number)", font: bodyFont, size: 9, style: paragraph(.center)))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.textPosition = CGPoint(x: box.midX - CGFloat(width) / 2, y: margin / 2)
    CTLineDraw(line, context)
  }

  private func text(_ string: String, font: String, size: CGFloat, style: CTParagraphStyle)
    -> NSAttributedString
  {
    NSAttributedString(
      string: string,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          font as CFString, size, nil),
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
      ])
  }

  private func paragraph(
    _ alignment: CTTextAlignment, firstIndent: CGFloat = 0, after: CGFloat = 0,
    lineSpacing: CGFloat = 0
  ) -> CTParagraphStyle {
    var alignment = alignment
    var firstIndent = firstIndent
    var after = after
    var lineSpacing = lineSpacing
    return withUnsafeBytes(of: &alignment) { a in
      withUnsafeBytes(of: &firstIndent) { f in
        withUnsafeBytes(of: &after) { s in
          withUnsafeBytes(of: &lineSpacing) { l in
            let settings = [
              CTParagraphStyleSetting(
                spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                value: a.baseAddress!),
              CTParagraphStyleSetting(
                spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size,
                value: f.baseAddress!),
              CTParagraphStyleSetting(
                spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size,
                value: s.baseAddress!),
              CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                value: l.baseAddress!),
            ]
            return CTParagraphStyleCreate(settings, settings.count)
          }
        }
      }
    }
  }

  // MARK: outline

  /// "Title Page", then one entry per section, nested by TOC depth, in the
  /// dictionary form `CGPDFContextSetOutline` takes (1-based destinations).
  private func outline(_ book: PdfBook, sectionStarts: [Int]) -> [String: Any] {
    final class Node {
      let title: String
      let page: Int
      let depth: Int
      var children: [Node] = []
      init(_ title: String, page: Int, depth: Int) {
        self.title = title
        self.page = page
        self.depth = depth
      }
      var dictionary: [String: Any] {
        var entry: [String: Any] = [
          kCGPDFOutlineTitle as String: title,
          kCGPDFOutlineDestination as String: page + 1,
        ]
        if !children.isEmpty {
          entry[kCGPDFOutlineChildren as String] = children.map(\.dictionary)
        }
        return entry
      }
    }

    let root = Node("", page: 0, depth: -1)
    root.children.append(Node("Title Page", page: 0, depth: 0))

    // The innermost open entries, outermost first.
    var stack: [Node] = [root]
    for (section, start) in zip(book.sections, sectionStarts) {
      let depth = max(section.depth, 0)
      while let last = stack.last, last !== root, last.depth >= depth { stack.removeLast() }
      let node = Node(section.label, page: start, depth: depth)
      stack.last?.children.append(node)
      stack.append(node)
    }

    return [kCGPDFOutlineChildren as String: root.children.map(\.dictionary)]
  }
}
