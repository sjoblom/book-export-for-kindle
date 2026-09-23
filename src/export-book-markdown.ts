import 'dotenv/config'

import fs from 'node:fs/promises'
import path from 'node:path'

import type { BookMetadata, ContentChunk } from './types'
import { readContentStore, selectReusableChunks } from './content-store'
import { formatContentChunks } from './postprocess-text'
import { resolveBookSections } from './toc-sections'
import { assert, normalizeAuthors, readJsonFile } from './utils'

const MAX_MARKDOWN_FILENAME_STEM_LENGTH = 80

function truncateFilenameStem(stem: string): string {
  if (stem.length <= MAX_MARKDOWN_FILENAME_STEM_LENGTH) return stem

  const clipped = stem
    .slice(0, MAX_MARKDOWN_FILENAME_STEM_LENGTH)
    .replaceAll(/_[^_]*$/g, '')
    .replaceAll(/_+$/g, '')

  return clipped || stem.slice(0, MAX_MARKDOWN_FILENAME_STEM_LENGTH)
}

function filenameFromTitle(title: string): string {
  const slug = title
    .normalize('NFKD')
    .replaceAll(/[\u0300-\u036F]/g, '')
    .replaceAll('&', ' and ')
    .replaceAll(/['\u2019]/g, '')
    .replaceAll(/[^\da-zA-Z]+/g, '_')
    .replaceAll(/_+/g, '_')
    .replaceAll(/^_+|_+$/g, '')
    .toLowerCase()

  return `${truncateFilenameStem(slug || 'book')}.md`
}

function formatChunks(
  chunks: ContentChunk[],
  { headingLevel, sectionLabel, nextSectionLabel }: FormatChunksOptions = {}
): string {
  return formatContentChunks(chunks, {
    headingLevel,
    sectionLabel,
    nextSectionLabel
  })
}

interface FormatChunksOptions {
  headingLevel?: number
  sectionLabel?: string
  nextSectionLabel?: string
}

/**
 * GitHub's heading anchor for `text`, as github-slugger computes it.
 *
 * Lowercase, drop everything that isn't a letter, mark, number, connector
 * (`_`), hyphen or space, then turn each space into a hyphen. Letters outside
 * ASCII survive, so "Café" is `café` rather than `caf-`, and apostrophes
 * vanish rather than splitting a word, so "What's Next?" is `whats-next`.
 */
export function githubSlug(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replaceAll(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, '')
    .replaceAll(' ', '-')
}

/**
 * Assigns anchors the way GitHub does across one document.
 *
 * Repeated headings share a base slug, so GitHub numbers the later ones
 * `-1`, `-2`, … in document order. A link can therefore only be right if
 * every heading before its target went through the same slugger first.
 */
export function createGithubSlugger(): (text: string) => string {
  const occurrences = new Map<string, number>()

  return (text) => {
    const base = githubSlug(text)
    let slug = base
    while (occurrences.has(slug)) {
      const next = (occurrences.get(base) ?? 0) + 1
      occurrences.set(base, next)
      slug = `${base}-${next}`
    }
    occurrences.set(slug, 0)
    return slug
  }
}

/** ATX heading openers, as `formatContentChunks` writes them. */
const MARKDOWN_HEADING_REGEX = /^#{1,6} /

/** The text of every heading in `markdown`, in document order. */
function markdownHeadings(markdown: string): string[] {
  const headings: string[] = []
  for (const line of markdown.split('\n')) {
    if (!MARKDOWN_HEADING_REGEX.test(line)) continue
    // A trailing run of `#` after a space closes an ATX heading and is not
    // part of the text GitHub slugs.
    headings.push(
      line.replace(MARKDOWN_HEADING_REGEX, '').replace(/\s#+\s*$/, '')
    )
  }
  return headings
}

export interface ExportBookMarkdownOptions {
  asin: string
  /** Root directory holding one folder per ASIN. Defaults to `out`. */
  outDir?: string
  /**
   * The book's text, when the caller has already read it.
   *
   * It is filtered against the metadata on disk exactly as `content.json`
   * would be, so passing it saves a read without widening what gets exported.
   */
  content?: ContentChunk[]
}

/**
 * Render an already-transcribed book to markdown.
 *
 * Returns the path written.
 */
export async function exportBookMarkdown({
  asin,
  outDir: root = 'out',
  content: provided
}: ExportBookMarkdownOptions): Promise<string> {
  const outDir = path.join(root, asin)

  const metadata = await readJsonFile<BookMetadata>(
    path.join(outDir, 'metadata.json')
  )
  // Export only what the pipeline's checks would accept: text from this
  // capture's pages, one chunk per page, each with actual text. Rendering
  // `content.json` as-is would print a stale capture or duplicate pages that
  // every completeness check had already discounted.
  const content = selectReusableChunks(
    provided
      ? { captureId: metadata.captureId, chunks: provided }
      : await readContentStore(outDir),
    metadata
  )
  assert(content.length, 'no book content found')
  assert(metadata.meta, 'invalid book metadata: missing meta')
  assert(metadata.toc?.length, 'invalid book metadata: missing toc')

  const title = metadata.meta.title
  // Normalized here too: books captured before authors were normalized at
  // capture time still hold Amazon's raw `Last, First:` string.
  const authors = normalizeAuthors(metadata.meta.authorList ?? [])
  const publisher = metadata.meta.publisher
  const totalPages = metadata.nav.totalNumContentPages
  const bookAsin = metadata.meta.asin
  // Format release date from DD/MM/YYYY to a human-friendly format
  const formattedDate = (() => {
    const raw = metadata.meta.releaseDate
    if (!raw) return undefined
    const [day, month, year] = raw.split('/')
    const date = new Date(Number(year), Number(month) - 1, Number(day))
    if (Number.isNaN(date.getTime())) return raw
    return date.toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    })
  })()

  // Format language code to display name
  const formattedLanguage = (() => {
    const code = metadata.meta.language
    if (!code) return undefined
    try {
      const displayNames = new Intl.DisplayNames(['en'], { type: 'language' })
      return displayNames.of(code)
    } catch {
      return code
    }
  })()

  const sections = resolveBookSections(metadata.toc, content)
  assert(sections.length, 'no book sections could be resolved')

  // Build a condensed TOC summary (top-level items only)
  const topLevelTocItems = sections
    .map((section) => section.tocItem)
    .filter((tocItem) => tocItem.depth === 0)
  const tocSummary = topLevelTocItems
    .map((item) => `- ${item.label}`)
    .join('\n')

  // Build the details table, only including rows where data is available
  const detailRows: Array<[string, string | number]> = []
  if (publisher) detailRows.push(['Publisher', publisher])
  if (formattedDate) detailRows.push(['Release Date', formattedDate])
  if (formattedLanguage) detailRows.push(['Language', formattedLanguage])
  if (totalPages) detailRows.push(['Pages', totalPages])
  if (topLevelTocItems.length)
    detailRows.push(['Chapters', topLevelTocItems.length])
  if (bookAsin) detailRows.push(['ASIN', bookAsin])

  const detailsTable = detailRows.length
    ? `| | |
|---|---|
${detailRows.map(([label, value]) => `| **${label}** | ${value} |`).join('\n')}`
    : ''

  const bodies = sections.map(({ tocItem, chunks, nextLabel }) =>
    formatChunks(chunks, {
      // Section headings found in the body nest under the TOC heading below.
      headingLevel: tocItem.depth + 3,
      sectionLabel: tocItem.label,
      nextSectionLabel: nextLabel
    })
  )

  // Anchors depend on every heading that comes before them, including the
  // fixed ones here and the headings detected inside each section's body, so
  // they are assigned by walking the headings in the order they will appear.
  const slug = createGithubSlugger()
  for (const heading of [
    title,
    'Book Details',
    'Chapter Overview',
    'Table of Contents'
  ]) {
    slug(heading)
  }
  const anchors = sections.map(({ tocItem }, i) => {
    const anchor = slug(tocItem.label)
    for (const heading of markdownHeadings(bodies[i]!)) slug(heading)
    return anchor
  })

  let output = `# ${title}

> By ${authors.join(', ')}

## Book Details

${detailsTable}

## Chapter Overview

${tocSummary}

---

## Table of Contents

${sections
  .map(
    ({ tocItem }, i) =>
      `${'  '.repeat(tocItem.depth)}- [${tocItem.label}](#${anchors[i]})`
  )
  .join('\n')}

---`

  for (const [i, { tocItem }] of sections.entries()) {
    output += `

${'#'.repeat(tocItem.depth + 2)} ${tocItem.label}

${bodies[i]}`
  }

  const outputPath = path.join(outDir, filenameFromTitle(title))
  await fs.writeFile(outputPath, output)

  return outputPath
}
