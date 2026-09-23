import type { BrowserContext } from './extract-kindle-book'
import { type LibraryBook, parseLibraryPage } from './library-page'
import { SIGNED_OUT_PATH_REGEX } from './session'

export {
  type LibraryBook,
  type LibraryPage,
  parseLibraryPage,
  safeCoverUrl
} from './library-page'

/**
 * Reading the signed-in account's Kindle library.
 *
 * The library page fetches its own contents from an internal JSON endpoint, so
 * we call that from inside the page rather than scraping the DOM — the markup
 * is virtualised and changes often, whereas the payload is stable and already
 * carries exactly the fields we need.
 */

const LIBRARY_URL = 'https://read.amazon.com/kindle-library'
const SEARCH_PATH = '/kindle-library/search'
const DEFAULT_PAGE_SIZE = 50

/** Guard against an unbounded loop if the endpoint keeps returning a token. */
const MAX_PAGES = 40

export class NotSignedInError extends Error {
  constructor() {
    super("not signed in to Amazon — run 'book-export login' first")
    this.name = 'NotSignedInError'
  }
}

export interface FetchLibraryOptions {
  /** Books requested per round trip. */
  pageSize?: number
  /** Stop after this many books. */
  limit?: number
  onProgress?: (count: number) => void
}

/**
 * Every book in the signed-in account's Kindle library, newest first.
 */
export async function fetchLibrary(
  context: BrowserContext,
  { pageSize = DEFAULT_PAGE_SIZE, limit, onProgress }: FetchLibraryOptions = {}
): Promise<LibraryBook[]> {
  const page = context.pages()[0] ?? (await context.newPage())

  if (!page.url().startsWith('https://read.amazon.com')) {
    await page.goto(LIBRARY_URL, { waitUntil: 'domcontentloaded' })
  }

  if (SIGNED_OUT_PATH_REGEX.test(new URL(page.url()).pathname)) {
    throw new NotSignedInError()
  }

  const books: LibraryBook[] = []
  const seen = new Set<string>()
  let paginationToken: string | undefined

  for (let request = 0; request < MAX_PAGES; request++) {
    const payload = await page.evaluate(
      async ({ searchPath, querySize, token }) => {
        // This callback runs in the page, where `globalThis` carries the
        // browser's `location`; the Node types in scope here don't know that.
        const { origin } = (
          globalThis as unknown as { location: { origin: string } }
        ).location
        const url = new URL(searchPath, origin)
        url.searchParams.set('query', '')
        url.searchParams.set('libraryType', 'BOOKS')
        url.searchParams.set('sortType', 'recency')
        url.searchParams.set('querySize', String(querySize))
        if (token) url.searchParams.set('paginationToken', token)

        const res = await fetch(url.toString(), {
          credentials: 'include',
          headers: { accept: 'application/json' }
        })

        if (!res.ok) {
          return { __error: `${res.status} ${res.statusText}` }
        }

        return res.json()
      },
      { searchPath: SEARCH_PATH, querySize: pageSize, token: paginationToken }
    )

    const error = (payload as Record<string, unknown> | undefined)?.__error
    if (typeof error === 'string') {
      if (error.startsWith('401') || error.startsWith('403')) {
        throw new NotSignedInError()
      }

      throw new Error(`Kindle library request failed: ${error}`)
    }

    const parsed = parseLibraryPage(payload)
    for (const book of parsed.books) {
      // The endpoint can repeat entries across pages; keep the first.
      if (seen.has(book.asin)) continue

      seen.add(book.asin)
      books.push(book)
    }

    onProgress?.(books.length)

    if (limit && books.length >= limit) return books.slice(0, limit)
    if (!parsed.paginationToken || !parsed.books.length) break

    paginationToken = parsed.paginationToken
  }

  return books
}
