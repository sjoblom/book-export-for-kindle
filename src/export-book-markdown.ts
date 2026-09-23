import 'dotenv/config'

import fs from 'node:fs/promises'
import path from 'node:path'

import type { BookMetadata, ContentChunk } from './types'
import { renderBookMarkdown } from './book-markdown'
import { readContentStore } from './content-store'
import { readJsonFile } from './utils'

export { createGithubSlugger, githubSlug } from './book-markdown'

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
  const { fileName, markdown } = renderBookMarkdown(
    metadata,
    provided ?? (await readContentStore(outDir))
  )

  const outputPath = path.join(outDir, fileName)
  await fs.writeFile(outputPath, markdown)

  return outputPath
}
