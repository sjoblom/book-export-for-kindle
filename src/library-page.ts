import { normalizeAuthors } from './pure-utils'

/**
 * Parsing the Kindle library endpoint's payload.
 *
 * Apart from `kindle-library.ts`, which drives the browser to fetch it, so the
 * native app's JavaScriptCore bundle (`src/core`) parses exactly the same way.
 */

export interface LibraryBook {
  asin: string
  title: string
  authors: string[]
  /** `EBOOK`, `KINDLE_EDITION_WITH_AUDIO`, … — samples and audiobooks differ. */
  resourceType?: string
  /** 0-100, when Amazon reports reading progress. */
  percentageRead?: number
  /**
   * The cover thumbnail Amazon shows in its own library, when it sent one.
   * Always an https URL on Amazon's image hosts; see `safeCoverUrl`.
   */
  coverUrl?: string
}

export interface LibraryPage {
  books: LibraryBook[]
  paginationToken?: string
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

/**
 * Hosts Amazon serves product images from. The web app puts this URL straight
 * into an `<img>`, so anything else — another site, plain http, a `javascript:`
 * or `data:` URL — is dropped rather than rendered.
 */
const COVER_HOSTS = [
  'media-amazon.com',
  'images-amazon.com',
  'ssl-images-amazon.com'
]

/**
 * The cover URL if it is an https image on one of Amazon's image hosts,
 * otherwise `undefined`.
 *
 * Exported because the web app's library cache is read back from disk, where
 * a hand-edited or stale file deserves the same scrutiny as the live payload.
 */
export function safeCoverUrl(value: unknown): string | undefined {
  const raw = asString(value)
  if (!raw) return

  const parsed = parseHttpsUrl(raw)
  if (!parsed) return

  const host = parsed.host.toLowerCase()
  const onAmazon = COVER_HOSTS.some(
    (allowed) => host === allowed || host.endsWith(`.${allowed}`)
  )

  return onAmazon ? parsed.href : undefined
}

/**
 * The host and normalized form of an https URL with no credentials, or
 * `undefined` for anything else.
 *
 * Node and browsers parse with WHATWG `URL`. JavaScriptCore on its own (the
 * native app runs this module there) has no `URL`, so it gets a deliberately
 * narrower hand parse: a plain hostname made of letters, digits, dots and
 * hyphens, then an optional port and path. Anything that shape rejects, such
 * as `user@host` or a backslash that `URL` would read as a slash, is dropped,
 * which is the safe direction for a value that ends up in an `<img>`.
 */
function parseHttpsUrl(
  raw: string
): { host: string; href: string } | undefined {
  if (typeof URL === 'function') {
    let url: URL
    try {
      url = new URL(raw)
    } catch {
      return
    }

    if (url.protocol !== 'https:' || url.username || url.password) return
    return { host: url.hostname, href: url.toString() }
  }

  if (!/^https:\/\//i.test(raw) || /\s/.test(raw)) return
  const authority = raw.slice('https://'.length).split(/[#/?]/, 1)[0]!
  const [host = '', port, ...extra] = authority.split(':')
  if (!/^[\d.a-z-]+$/i.test(host)) return
  if (extra.length || (port !== undefined && !/^\d{1,5}$/.test(port))) return

  return { host, href: raw }
}

/**
 * Amazon packs every author into one colon-delimited string, each written
 * "Last, First" — `"Alonso, Ana:Callaghan, Harrison:"`. Splitting on commas
 * would turn one author into two. `normalizeAuthors` already handles this
 * shape, including the trailing separator.
 */
function parseAuthors(value: unknown): string[] {
  const entries = (Array.isArray(value) ? value : [value])
    .map((entry) => asString(entry))
    .filter((entry): entry is string => !!entry)

  return entries.flatMap((entry) => normalizeAuthors([entry]))
}

/**
 * Pull the books out of one library response.
 *
 * Kept separate from the network call so it can be tested against a recorded
 * payload — the shape is Amazon's to change, and a silent parse failure here
 * would look identical to an empty library.
 */
export function parseLibraryPage(payload: unknown): LibraryPage {
  if (!payload || typeof payload !== 'object') return { books: [] }

  const record = payload as Record<string, unknown>
  const rawItems = record.itemsList ?? record.items ?? record.OwnedItems
  if (!Array.isArray(rawItems)) return { books: [] }

  const books: LibraryBook[] = []
  for (const item of rawItems) {
    if (!item || typeof item !== 'object') continue

    const entry = item as Record<string, unknown>
    const rawAsin = asString(entry.asin) ?? asString(entry.ASIN)
    if (!rawAsin) continue

    const asin = rawAsin.toUpperCase()
    books.push({
      asin,
      title: asString(entry.title) ?? asin,
      authors: parseAuthors(entry.authors ?? entry.author),
      resourceType: asString(entry.resourceType),
      percentageRead:
        typeof entry.percentageRead === 'number'
          ? entry.percentageRead
          : undefined,
      // Despite its name, `productUrl` holds the cover thumbnail — an
      // m.media-amazon.com image — which is what the live endpoint returned
      // when this was written.
      coverUrl: safeCoverUrl(entry.productUrl)
    })
  }

  return {
    books,
    paginationToken:
      asString(record.paginationToken) ?? asString(record.nextPageToken)
  }
}
