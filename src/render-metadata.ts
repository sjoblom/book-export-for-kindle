import type {
  AmazonBookInfo,
  AmazonBookMeta,
  AmazonRenderLocationMap,
  AmazonRenderToc,
  AmazonRenderTocItem,
  Nav,
  PageNav,
  TocItem
} from './types'
import { parseTocItems } from './playwright-utils'
import { assert, normalizeAuthors, parseJsonpResponse } from './pure-utils'

/**
 * Turning what the Kindle reader downloads into a book's metadata.
 *
 * The reader tells us about a book in three kinds of response: the cold-open
 * `YJmetadata.jsonp` and `startReading` calls, and the `/renderer/render` TAR
 * files, whose `location_map.json`, `metadata.json` and `toc.json` carry the
 * page numbering and the table of contents. Both capture paths — the CLI's
 * Playwright network handlers and the native app's `fetch` hook — feed those
 * responses through here, so a book captured by either ends up with the same
 * `metadata.json`.
 *
 * The functions mutate a shared state object rather than returning fresh ones
 * because responses arrive one at a time, in whatever order the reader asks
 * for them, and the CLI applies each as it lands. Which response wins when two
 * disagree is part of the behaviour (the first TOC, the last location map, the
 * YJ metadata over the render fallback only if it came first), so the order of
 * calls is the caller's to preserve.
 */

/** The parts of `BookMetadata` that come from the reader's responses. */
export interface RenderMetadataState {
  meta?: AmazonBookMeta
  info?: AmazonBookInfo
  toc?: TocItem[]
  locationMap?: AmazonRenderLocationMap
  nav: Nav
}

/** The raw text of the files in one `/renderer/render` TAR. */
export interface RenderFiles {
  toc?: string | null
  locationMap?: string | null
  metadata?: string | null
}

/** Every nav field unknown, as a capture starts out. */
export function emptyNav(): Nav {
  return {
    startPosition: -1,
    endPosition: -1,
    startContentPosition: -1,
    startContentPage: -1,
    endContentPosition: -1,
    endContentPage: -1,
    totalNumPages: -1,
    totalNumContentPages: -1
  }
}

/**
 * The book page a reader position falls on, or -1 while no location map has
 * arrived.
 *
 * A position before the first navigation unit counts as page 1: that is the
 * cover and front matter, which Kindle leaves unnumbered.
 */
export function pageForPosition(
  locationMap: Pick<AmazonRenderLocationMap, 'navigationUnit'> | undefined,
  position: number
): number {
  if (!locationMap) return -1

  let resultPage = 1

  // TODO: this is O(n) but we can do better
  for (const { startPosition, page } of locationMap.navigationUnit) {
    if (startPosition > position) break

    resultPage = page
  }

  return resultPage
}

/**
 * The page the reader's footer is on.
 *
 * The footer reports a location rather than a page in front and back matter,
 * and for roman-numbered pages; those are mapped through the location map.
 * With no footer at all the caller's own count is the best there is.
 */
export function normalizePageNumber(
  pageNav: PageNav | undefined,
  locationMap: Pick<AmazonRenderLocationMap, 'navigationUnit'> | undefined,
  fallbackPage: number
): number {
  if (!pageNav) return fallbackPage
  if (pageNav.page !== undefined) return pageNav.page
  if (pageNav.location !== undefined) {
    return pageForPosition(locationMap, pageNav.location)
  }

  return fallbackPage
}

/** Flatten one of Amazon's nested TOC entries, depth first. */
export function tocItemsFromRender(
  rawTocItem: AmazonRenderTocItem,
  locationMap: Pick<AmazonRenderLocationMap, 'navigationUnit'> | undefined,
  { depth = 0 }: { depth?: number } = {}
): TocItem[] {
  const positionId = rawTocItem.tocPositionId
  const page = pageForPosition(locationMap, positionId)

  const tocItem: TocItem = {
    label: rawTocItem.label,
    positionId,
    page,
    depth
  }

  const tocItems: TocItem[] = [tocItem]

  if (rawTocItem.entries) {
    for (const rawTocItemEntry of rawTocItem.entries) {
      tocItems.push(
        ...tocItemsFromRender(rawTocItemEntry, locationMap, {
          depth: depth + 1
        })
      )
    }
  }

  return tocItems
}

/**
 * Record the `YJmetadata.jsonp` payload (parsed, or the JSONP text itself).
 *
 * Returns the stored meta when this call set it, so the caller can log it.
 * Metadata for another ASIN is ignored: the reader also fetches it for
 * recommendations. The first payload wins, including over the render fallback
 * — but only if it arrives before that fallback is synthesized.
 */
export function applyYjMetadata(
  state: RenderMetadataState,
  payload: unknown,
  asin: string
): AmazonBookMeta | undefined {
  const parsed =
    typeof payload === 'string' ? parseJsonpResponse<any>(payload) : payload
  if (!parsed || typeof parsed !== 'object') return
  // A copy, so a caller's parsed response is not edited behind its back. The
  // spread keeps key order, which is what ends up in `metadata.json`.
  const metadata: any = { ...parsed }
  if (metadata.asin !== asin) return

  delete metadata.cpr

  // Amazon sends authors as `"Last, First:Last2, First2:"`. Every reader
  // of the stored metadata (the exporters, book-status) reads
  // `authorList`, so that is the field to normalize; `authorsList` is
  // accepted too in case Amazon ever spells it that way, but it is
  // folded into `authorList` so the stored shape stays the one
  // `AmazonBookMeta` declares.
  const rawAuthors: unknown = Array.isArray(metadata.authorList)
    ? metadata.authorList
    : metadata.authorsList
  delete metadata.authorsList
  metadata.authorList = Array.isArray(rawAuthors)
    ? normalizeAuthors(rawAuthors.map(String))
    : []

  if (state.meta) return

  state.meta = metadata
  return metadata
}

/**
 * Record the `startReading` payload. The latest one wins; it carries session
 * tokens that are dropped rather than written to disk.
 *
 * Returns whether this was the first one, so the caller can log it once.
 */
export function applyStartReading(
  state: RenderMetadataState,
  payload: unknown
): boolean {
  if (!payload || typeof payload !== 'object') return false

  const body: any = { ...payload }
  delete body.karamelToken
  delete body.metadataUrl
  delete body.YJFormatVersion

  const first = !state.info
  state.info = body
  return first
}

function parseJson<T>(text: string | null | undefined): T | undefined {
  if (typeof text !== 'string') return
  try {
    return JSON.parse(text) as T
  } catch {}
}

/**
 * Record one `/renderer/render` TAR's files.
 *
 * Throws on a malformed file part-way through, leaving what was applied
 * before it; callers ignore the error, as one bad render must not end a
 * capture that the next render can still inform.
 */
export function applyRenderFiles(
  state: RenderMetadataState,
  files: RenderFiles,
  asin: string
): void {
  const locationMap = parseJson<Partial<AmazonRenderLocationMap>>(
    files.locationMap
  )
  if (locationMap) {
    const locations = Array.isArray(locationMap.locations)
      ? locationMap.locations
      : []
    const rawNavigationUnit = Array.isArray(locationMap.navigationUnit)
      ? locationMap.navigationUnit
      : []

    // Books without print page numbers have no navigation units; Kindle's
    // own footer then counts locations, so each one is a page.
    const navigationUnit =
      rawNavigationUnit.length > 0
        ? rawNavigationUnit
        : locations.map((startPosition, index) => ({
            startPosition,
            label: `${index + 1}`,
            page: index + 1
          }))

    // Roman-numbered front matter has labels that don't parse; those fall
    // back to their ordinal so page numbers still only ever increase.
    for (const [index, navUnit] of navigationUnit.entries()) {
      const parsedPage = Number.parseInt(
        `${navUnit.page ?? navUnit.label ?? ''}`,
        10
      )
      navUnit.page = Number.isNaN(parsedPage) ? index + 1 : parsedPage
    }

    state.locationMap = {
      locations,
      navigationUnit
    }
  }

  const metadata = parseJson<any>(files.metadata)
  if (metadata) {
    state.nav.startPosition = metadata.firstPositionId
    state.nav.endPosition = metadata.lastPositionId

    // Fallback for books opened in "resume" mode: when the account
    // has existing reading progress, the web reader skips the
    // cold-open `startReading` and `YJmetadata.jsonp` requests, so
    // `info` / `meta` never arrive over the network.
    // The render metadata carries the whole-book range plus
    // title/author, so synthesize the minimal fields we depend on.
    if (!state.meta) {
      state.meta = {
        asin,
        title: metadata.bookTitle,
        authorList: Array.isArray(metadata.authors)
          ? normalizeAuthors(metadata.authors)
          : [],
        language: metadata.lang ?? '',
        positions: {
          cover: metadata.coverPosistion ?? 0,
          srl: metadata.srl ?? 0,
          toc: 0
        },
        sample: false,
        startPosition: metadata.firstPositionId,
        endPosition: metadata.lastPositionId
      } as any
    }
    if (!state.info) {
      state.info = {
        requestedAsin: asin,
        deliveredAsin: asin,
        isOwned: true,
        isSample: false,
        srl: metadata.srl ?? 0
      } as any
    }
  }

  // Pages come from the location map, so a TOC that arrives before one is
  // kept waiting for a later render rather than recorded with no pages.
  const rawToc = parseJson<AmazonRenderToc>(files.toc)
  if (rawToc && state.locationMap && !state.toc) {
    const toc: TocItem[] = []

    for (const rawTocItem of rawToc) {
      toc.push(
        ...tocItemsFromRender(rawTocItem, state.locationMap, { depth: 0 })
      )
    }

    state.toc = toc
  }
}

/**
 * Work out the book's page range once the reader has loaded.
 *
 * Throws when the responses never said enough to capture the book. Returns
 * whether the TOC had to be made up, which the caller should warn about: every
 * section heading in the export will then be missing.
 */
export function finalizeBookNav(state: RenderMetadataState): {
  usedFallbackToc: boolean
} {
  assert(state.info, 'expected book info to be initialized')
  assert(state.meta, 'expected book meta to be initialized')
  assert(state.locationMap, 'expected book location map to be initialized')

  let usedFallbackToc = false
  if (!state.toc?.length) {
    usedFallbackToc = true
    state.toc = [
      {
        label: 'Start',
        positionId: state.meta.startPosition,
        page: pageForPosition(state.locationMap, state.meta.startPosition),
        depth: 0
      }
    ]
  }

  const { nav } = state
  nav.startContentPosition = state.meta.startPosition
  nav.totalNumPages = state.locationMap.navigationUnit.reduce(
    (acc, navUnit) => {
      return Math.max(acc, navUnit.page ?? -1)
    },
    -1
  )
  assert(nav.totalNumPages > 0, 'parsed book nav has no pages')
  nav.startContentPage = pageForPosition(
    state.locationMap,
    nav.startContentPosition
  )

  const parsedToc = parseTocItems(state.toc, {
    totalNumPages: nav.totalNumPages
  })
  nav.endContentPage =
    parsedToc.firstPostContentPageTocItem?.page ?? nav.totalNumPages
  nav.endContentPosition =
    parsedToc.firstPostContentPageTocItem?.positionId ?? nav.endPosition

  nav.totalNumContentPages = Math.min(
    parsedToc.firstPostContentPageTocItem?.page ?? nav.totalNumPages,
    nav.totalNumPages
  )
  assert(nav.totalNumContentPages > 0, 'No content pages found')

  return { usedFallbackToc }
}

export interface BuildBookMetadataInput {
  asin: string
  /** Each render TAR's files, in the order the reader received them. */
  renders: RenderFiles[]
  /** The `YJmetadata.jsonp` payload, parsed or as the JSONP text. */
  yjMetadata?: unknown
  /** The `startReading` response body. */
  startReading?: unknown
}

export interface BuiltBookMetadata {
  meta: AmazonBookMeta
  info: AmazonBookInfo
  toc: TocItem[]
  locationMap: AmazonRenderLocationMap
  nav: Nav
}

/**
 * Everything the reader's responses say about a book, in one call.
 *
 * For a caller that collects the responses first and computes afterwards, as
 * the native app does. The cold-open requests are applied before the renders,
 * the order the reader makes them in, so their metadata wins over the resume
 * fallback exactly as it does when the CLI sees them live. A render whose
 * files don't parse is skipped, as the CLI's network handler skips it.
 */
export function buildBookMetadata({
  asin,
  renders,
  yjMetadata,
  startReading
}: BuildBookMetadataInput): BuiltBookMetadata {
  const state: RenderMetadataState = { nav: emptyNav() }

  if (yjMetadata !== undefined && yjMetadata !== null) {
    applyYjMetadata(state, yjMetadata, asin)
  }
  if (startReading !== undefined && startReading !== null) {
    applyStartReading(state, startReading)
  }

  for (const render of renders ?? []) {
    try {
      applyRenderFiles(state, render ?? {}, asin)
    } catch {}
  }

  finalizeBookNav(state)

  return {
    meta: state.meta!,
    info: state.info!,
    toc: state.toc!,
    locationMap: state.locationMap!,
    nav: state.nav
  }
}
