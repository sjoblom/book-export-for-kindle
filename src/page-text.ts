import type { BookMetadata, ContentChunk, OcrLine, TocItem } from './types'
import { reconstructParagraphs } from './ocr-layout'
import { escapeRegExp } from './pure-utils'

export interface ShapePageTextOptions {
  /**
   * The TOC entry's label when this page opens that entry, so the heading
   * the OCR read off the top of the page isn't printed a second time under
   * the heading the exporter already writes for it.
   */
  tocLabelToStrip?: string
}

/**
 * Turn what an OCR engine read off one page into the page's stored text.
 *
 * This is the only place these rules live. The transcriber applies them as a
 * page is read, and the exporters apply them again to pages whose raw OCR
 * lines were kept, so a change here reaches books whose page images are long
 * gone. Two copies of the rules would let the two drift apart.
 */
export function shapePageText(
  rawText: string,
  { tocLabelToStrip }: ShapePageTextOptions = {}
): string {
  let text = rawText
    // A page number read off the top of the page. Only the very first line:
    // a digits-only line further down is content — a year as a heading, a
    // chapter number set mid-page — and used to be deleted.
    .replace(/^\s*\d+[ \t]*\n+/, '')
    .replaceAll(/^\s*/gm, '')
    .replaceAll(/\s*$/gm, '')

  if (tocLabelToStrip) {
    text = text.replace(
      // eslint-disable-next-line security/detect-non-literal-regexp
      new RegExp(`^${escapeRegExp(tocLabelToStrip)}\\s*`, 'i'),
      ''
    )
  }

  return text
}

/**
 * Decides which TOC label, if any, is stripped from the start of each page.
 *
 * A page only opens a TOC entry when it is the first capture of that book
 * page: Kindle can render one book page across several screens, and only the
 * first of them carries the heading. "First" is judged against the capture's
 * page list rather than whatever text happens to exist, so the transcriber
 * (which reads pages in any order) and the exporter agree on every page.
 */
export function createTocLabelResolver(
  metadata: Pick<BookMetadata, 'pages' | 'toc'>
): (chunk: Pick<ContentChunk, 'index' | 'page'>) => string | undefined {
  const pageToTocItem = new Map<number, TocItem>()
  for (const tocItem of metadata.toc ?? []) {
    // Several entries can start on one page. The last one wins, as it always
    // has, so re-derived text matches what the transcriber stored.
    if (tocItem.page !== undefined) pageToTocItem.set(tocItem.page, tocItem)
  }

  const pages = metadata.pages ?? []
  const positionByIndex = new Map(
    pages.map((pageChunk, position) => [pageChunk.index, position] as const)
  )

  return ({ index, page }) => {
    const position = positionByIndex.get(index)
    if (position === undefined) return undefined

    const prevPageChunk = pages[position - 1]
    if (!prevPageChunk || prevPageChunk.page === page) return undefined

    return pageToTocItem.get(page)?.label
  }
}

/**
 * `chunks` with each page's text rebuilt from its kept OCR lines under the
 * current rules.
 *
 * `content.json` keeps the text as it was first derived, and the raw lines
 * beside it. Exporting re-derives rather than trusting the stored text, so an
 * improvement to paragraph reconstruction reaches every book already read,
 * not just the ones read after it. The stored text is left alone as the
 * record of what the OCR run produced. Chunks without lines — read by a model
 * that sees prose, or transcribed before lines were kept — have nothing to
 * rebuild from and keep their text.
 */
export function withCurrentText(
  chunks: ContentChunk[],
  metadata: Pick<BookMetadata, 'pages' | 'toc'>
): ContentChunk[] {
  const tocLabelFor = createTocLabelResolver(metadata)

  return chunks.map((chunk) => {
    if (!chunk.lines?.length) return chunk

    const text = shapePageText(reconstructParagraphs(chunk.lines), {
      tocLabelToStrip: tocLabelFor(chunk)
    })
    return text === chunk.text ? chunk : { ...chunk, text }
  })
}

/**
 * A page's stored text from the lines an OCR engine read off it — the whole
 * derivation the transcriber applies, for a caller that runs the engine itself
 * (the native app, with Vision).
 */
export function pageTextFromLines(
  lines: OcrLine[],
  tocLabelToStrip?: string
): string {
  return shapePageText(reconstructParagraphs(lines), { tocLabelToStrip })
}

/**
 * `createTocLabelResolver` applied to every chunk at once, `null` where a page
 * opens no TOC entry — for callers that can only exchange plain data.
 */
export function tocLabelsForChunks(
  metadata: Pick<BookMetadata, 'pages' | 'toc'>,
  chunks: Pick<ContentChunk, 'index' | 'page'>[]
): Array<string | null> {
  const tocLabelFor = createTocLabelResolver(metadata)
  return chunks.map((chunk) => tocLabelFor(chunk) ?? null)
}
