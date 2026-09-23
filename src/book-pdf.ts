import type { BookMetadata, ContentChunk, ContentStore } from './types'
import { exportableChunks } from './book-markdown'
import { formatContentChunks } from './postprocess-text'
import { assert, normalizeAuthors } from './pure-utils'
import { resolveBookSections } from './toc-sections'

// What goes into the PDF, decided apart from how it is drawn. pdfkit draws it
// for the CLI and the native app draws it natively; both get their text and
// sections from here so the two PDFs say the same thing.

export interface PdfSection {
  label: string
  /** TOC depth, 0 for top level; decides the title size. */
  depth: number
  /** The section's paragraphs, separated by blank lines. */
  text: string
}

export interface PdfDocumentContent {
  title: string
  authors: string[]
  sections: PdfSection[]
}

/** The title page and every section of an already-transcribed book. */
export function pdfDocument(
  metadata: BookMetadata,
  content: ContentStore | ContentChunk[] | null | undefined
): PdfDocumentContent {
  const chunks = exportableChunks(metadata, content)
  assert(chunks.length, 'no book content found')
  assert(metadata.meta, 'invalid book metadata: missing meta')
  assert(metadata.toc?.length, 'invalid book metadata: missing toc')

  const title = metadata.meta.title
  // Normalized here too: books captured before authors were normalized at
  // capture time still hold Amazon's raw `Last, First:` string.
  const authors = normalizeAuthors(metadata.meta.authorList ?? [])

  const sections = resolveBookSections(metadata.toc, chunks).map(
    ({ tocItem, chunks: sectionChunks, nextLabel }) => ({
      label: tocItem.label,
      depth: tocItem.depth,
      // Aggregate all of the chunks in this chapter into a single string.
      // Headings stay plain paragraphs here since a PDF renderer draws raw
      // text rather than markdown.
      text: formatContentChunks(sectionChunks, {
        detectHeadings: false,
        sectionLabel: tocItem.label,
        nextSectionLabel: nextLabel
      })
    })
  )

  return { title, authors, sections }
}
