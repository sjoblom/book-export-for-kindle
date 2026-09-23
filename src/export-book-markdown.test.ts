import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'

import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import type { BookMetadata, ContentChunk, ContentStore } from './types'
import { renderBookMarkdown } from './book-markdown'
import {
  createGithubSlugger,
  exportBookMarkdown,
  githubSlug
} from './export-book-markdown'

const ASIN = 'B00TEST'

let outDir: string

beforeEach(async () => {
  outDir = await fs.mkdtemp(path.join(os.tmpdir(), 'kindle-export-markdown-'))
})

afterEach(async () => {
  await fs.rm(outDir, { recursive: true, force: true })
})

function chunk(index: number, text: string): ContentChunk {
  return {
    index,
    page: index + 1,
    text,
    screenshot: `pages/00${index}.png`
  }
}

async function writeBook(
  chunks: unknown[],
  { captureId = 'capture-1' }: { captureId?: string } = {}
): Promise<void> {
  const bookDir = path.join(outDir, ASIN)
  await fs.mkdir(bookDir, { recursive: true })

  await fs.writeFile(
    path.join(bookDir, 'metadata.json'),
    JSON.stringify({
      captureId: 'capture-1',
      meta: { title: 'A Test Book', authorList: ['Doe, Jane'] },
      nav: { totalNumPages: 4, totalNumContentPages: 4 },
      toc: [
        { label: "What's Next?", positionId: 1, page: 1, depth: 0 },
        { label: 'Café', positionId: 2, page: 2, depth: 0 },
        { label: 'Notes', positionId: 3, page: 3, depth: 0 },
        { label: 'Notes', positionId: 4, page: 4, depth: 1 }
      ],
      pages: [0, 1, 2, 3].map((index) => ({
        index,
        page: index + 1,
        screenshot: `pages/00${index}.png`
      }))
    })
  )
  await fs.writeFile(
    path.join(bookDir, 'content.json'),
    JSON.stringify({ captureId, chunks })
  )
}

/** Every heading's anchor, computed independently from the written file. */
function headingAnchors(markdown: string): string[] {
  const slug = createGithubSlugger()
  return markdown
    .split('\n')
    .filter((line) => /^#{1,6} /.test(line))
    .map((line) => slug(line.replace(/^#+ /, '')))
}

function tocLinks(markdown: string): string[] {
  const toc = markdown.split('## Table of Contents')[1]!.split('---')[0]!
  return [...toc.matchAll(/\]\(#([^)]*)\)/g)].map((match) => match[1]!)
}

describe('githubSlug', () => {
  it('matches the anchors GitHub gives headings', () => {
    expect(githubSlug("What's Next?")).toBe('whats-next')
    expect(githubSlug('Café')).toBe('café')
    expect(githubSlug('1. The Mom Test')).toBe('1-the-mom-test')
    expect(githubSlug('Snake_case & Dashes - ok')).toBe(
      'snake_case--dashes---ok'
    )
    expect(githubSlug('Über «Straße»')).toBe('über-straße')
  })

  it('numbers repeated headings in document order', () => {
    const slug = createGithubSlugger()
    expect(slug('Notes')).toBe('notes')
    expect(slug('Notes')).toBe('notes-1')
    expect(slug('notes-1')).toBe('notes-1-1')
    expect(slug('Notes')).toBe('notes-2')
  })
})

describe('exportBookMarkdown', () => {
  it('links every TOC entry to the heading GitHub will anchor it at', async () => {
    await writeBook([
      chunk(0, 'Opening words.'),
      // A body heading that collides with a fixed heading shifts the numbering
      // for everything after it.
      chunk(1, 'Some prose.\n\nBOOK DETAILS\n\nMore prose.'),
      chunk(2, 'First notes.'),
      chunk(3, 'Second notes.')
    ])

    const markdown = await fs.readFile(
      await exportBookMarkdown({ asin: ASIN, outDir }),
      'utf8'
    )
    const links = tocLinks(markdown)

    expect(links).toEqual(['whats-next', 'café', 'notes', 'notes-1'])
    expect(headingAnchors(markdown)).toEqual(expect.arrayContaining(links))
    expect(headingAnchors(markdown)).toContain('book-details-1')
  })

  it('exports only chunks that belong to the capture on disk', async () => {
    await writeBook([
      chunk(0, 'Opening words.'),
      // A second copy of a page and a page with no text are not this book's
      // text, whatever content.json says.
      chunk(0, 'DUPLICATE PAGE TEXT'),
      { index: 1, page: 2, screenshot: 'pages/001.png' },
      chunk(2, 'First notes.'),
      chunk(3, 'Second notes.')
    ])

    const markdown = await fs.readFile(
      await exportBookMarkdown({ asin: ASIN, outDir }),
      'utf8'
    )

    expect(markdown).toContain('Opening words.')
    expect(markdown).not.toContain('DUPLICATE PAGE TEXT')
  })

  it('refuses a transcription from a different capture', async () => {
    await writeBook([chunk(0, 'Stale text.')], { captureId: 'capture-0' })

    await expect(exportBookMarkdown({ asin: ASIN, outDir })).rejects.toThrow(
      'no book content found'
    )
  })

  it('filters content handed to it the same way', async () => {
    await writeBook([])

    const markdown = await fs.readFile(
      await exportBookMarkdown({
        asin: ASIN,
        outDir,
        content: [
          chunk(0, 'Opening words.'),
          // Page 9 was never captured.
          { index: 8, page: 9, text: 'FOREIGN PAGE', screenshot: '' }
        ]
      }),
      'utf8'
    )

    expect(markdown).toContain('Opening words.')
    expect(markdown).not.toContain('FOREIGN PAGE')
  })

  it('rebuilds text from kept OCR lines instead of the stored text', async () => {
    await writeBook([
      {
        ...chunk(0, 'STALE first line that\nSTALE wraps on.'),
        // What the engine saw, which today's rules join into one paragraph.
        lines: [
          {
            text: 'A first line that',
            left: 40,
            top: 100,
            width: 820,
            height: 30
          },
          { text: 'wraps on.', left: 40, top: 145, width: 300, height: 30 }
        ]
      },
      // Read by a model, so there is nothing to rebuild from.
      chunk(1, 'Prose read by a model.'),
      chunk(2, 'First notes.'),
      chunk(3, 'Second notes.')
    ])

    const markdown = await fs.readFile(
      await exportBookMarkdown({ asin: ASIN, outDir }),
      'utf8'
    )

    expect(markdown).toContain('A first line that wraps on.')
    expect(markdown).not.toContain('STALE')
    expect(markdown).toContain('Prose read by a model.')

    // content.json keeps the text as the OCR run first produced it.
    const stored = JSON.parse(
      await fs.readFile(path.join(outDir, ASIN, 'content.json'), 'utf8')
    ) as { chunks: ContentChunk[] }
    expect(stored.chunks[0]!.text).toContain('STALE')
  })
})

describe('renderBookMarkdown', () => {
  it('is exactly what exportBookMarkdown writes', async () => {
    await writeBook([
      chunk(0, 'Opening words.'),
      chunk(1, 'Some prose.\n\nBOOK DETAILS\n\nMore prose.'),
      chunk(2, 'First notes.'),
      chunk(3, 'Second notes.')
    ])
    const bookDir = path.join(outDir, ASIN)
    const metadata = JSON.parse(
      await fs.readFile(path.join(bookDir, 'metadata.json'), 'utf8')
    ) as BookMetadata
    const store = JSON.parse(
      await fs.readFile(path.join(bookDir, 'content.json'), 'utf8')
    ) as ContentStore

    const written = await exportBookMarkdown({ asin: ASIN, outDir })
    const rendered = renderBookMarkdown(metadata, store)

    expect(path.basename(written)).toBe(rendered.fileName)
    expect(rendered.fileName).toBe('a_test_book.md')
    expect(await fs.readFile(written, 'utf8')).toBe(rendered.markdown)
    // Bare chunks are taken as this capture's, as `content` is by the export.
    expect(renderBookMarkdown(metadata, store.chunks)).toEqual(rendered)
  })

  it('checks a store against the capture it claims to be from', async () => {
    await writeBook([chunk(0, 'Stale text.')], { captureId: 'capture-0' })
    const bookDir = path.join(outDir, ASIN)
    const metadata = JSON.parse(
      await fs.readFile(path.join(bookDir, 'metadata.json'), 'utf8')
    ) as BookMetadata

    expect(() =>
      renderBookMarkdown(metadata, {
        captureId: 'capture-0',
        chunks: [chunk(0, 'Stale text.')]
      })
    ).toThrow('no book content found')
  })
})
