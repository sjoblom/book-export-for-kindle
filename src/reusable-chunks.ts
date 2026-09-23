import type { BookMetadata, ContentChunk, ContentStore } from './types'

// Lives apart from `content-store.ts`, which reads and writes the file, so the
// JavaScriptCore bundle in `src/core` can apply the same staleness rules
// without pulling in `node:fs`.

/**
 * The chunks of `store` that are genuinely text from `metadata`'s pages.
 *
 * Everything else is dropped, so a caller can treat the result as "what this
 * run does not have to read again" without checking anything itself.
 */
export function selectReusableChunks(
  store: ContentStore | undefined,
  metadata: Pick<BookMetadata, 'pages' | 'captureId'>
): ContentChunk[] {
  if (!store?.chunks?.length) return []
  const { chunks } = store

  const pageByIndex = new Map(
    (metadata.pages ?? []).map((page) => [page.index, page.page])
  )
  const belongs = (chunk: ContentChunk | undefined): boolean =>
    typeof chunk?.index === 'number' &&
    pageByIndex.get(chunk.index) === chunk.page

  if (metadata.captureId && store.captureId) {
    // Both sides know which capture they came from, so the answer is exact.
    if (metadata.captureId !== store.captureId) return []
  } else if (!chunks.every((chunk) => belongs(chunk))) {
    // One side predates capture ids, so fall back to what can be observed:
    // text covering pages this capture doesn't have is clearly from a
    // different one. Text that lines up may or may not be, and re-reading a
    // whole book on a maybe is the more expensive mistake.
    return []
  }

  const seen = new Set<number>()
  const reusable: ContentChunk[] = []
  for (const chunk of chunks) {
    if (!belongs(chunk) || seen.has(chunk.index)) continue
    // A blank page reads as an empty string, which is a real answer worth
    // keeping. A chunk with no text field at all is junk and gets read again.
    if (typeof chunk.text !== 'string') continue

    seen.add(chunk.index)
    reusable.push(chunk)
  }

  return reusable.toSorted((a, b) => a.index - b.index)
}
