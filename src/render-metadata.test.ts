import fs from 'node:fs'
import path from 'node:path'

import { describe, expect, it } from 'vitest'

import type { BookMetadata } from './types'
import {
  buildBookMetadata,
  normalizePageNumber,
  pageForPosition,
  type RenderFiles
} from './render-metadata'

const ASIN = 'B00TEST123'

// Shaped like the files in a real `/renderer/render` TAR: page labels are
// strings (roman in the front matter), `page` is absent and derived by us, and
// the TOC nests through `entries`.
const locationMap = {
  locations: [2, 3, 4, 51, 124, 255],
  navigationUnit: [
    { startPosition: 100, label: 'vii' },
    { startPosition: 1000, label: '1' },
    { startPosition: 2000, label: '2' },
    { startPosition: 3000, label: '3' },
    { startPosition: 4000, label: '4' },
    { startPosition: 5000, label: '5' },
    { startPosition: 6000, label: '6' },
    { startPosition: 7000, label: '7' },
    { startPosition: 8000, label: '8' },
    { startPosition: 9000, label: '9' },
    { startPosition: 9500, label: '10' }
  ]
}

const renderMetadata = {
  bookTitle: 'A Test Book',
  lang: 'en',
  authors: ['Doe, Jane:Roe, Richard:'],
  firstPositionId: 0,
  lastPositionId: 9999,
  srl: 1000,
  coverPosistion: 0,
  writingMode: 'horizontal_tb'
}

const toc = [
  { label: 'Cover', tocPositionId: 0 },
  {
    label: 'Part One',
    tocPositionId: 1000,
    entries: [
      { label: 'Chapter 1', tocPositionId: 1000 },
      { label: 'Chapter 2', tocPositionId: 4500 }
    ]
  },
  { label: 'Acknowledgements', tocPositionId: 9500 }
]

function render(files: {
  toc?: unknown
  locationMap?: unknown
  metadata?: unknown
}): RenderFiles {
  return {
    toc: files.toc === undefined ? undefined : JSON.stringify(files.toc),
    locationMap:
      files.locationMap === undefined
        ? undefined
        : JSON.stringify(files.locationMap),
    metadata:
      files.metadata === undefined ? undefined : JSON.stringify(files.metadata)
  }
}

const fullRender = render({ toc, locationMap, metadata: renderMetadata })

describe('buildBookMetadata', () => {
  it('reads a resumed book entirely from its render files', () => {
    const built = buildBookMetadata({ asin: ASIN, renders: [fullRender] })

    // No cold-open requests: meta and info are synthesized from the render.
    expect(built.meta).toEqual({
      asin: ASIN,
      title: 'A Test Book',
      authorList: ['Jane Doe', 'Richard Roe'],
      language: 'en',
      positions: { cover: 0, srl: 1000, toc: 0 },
      sample: false,
      startPosition: 0,
      endPosition: 9999
    })
    expect(built.info).toEqual({
      requestedAsin: ASIN,
      deliveredAsin: ASIN,
      isOwned: true,
      isSample: false,
      srl: 1000
    })

    // A roman label can't be a page number, so it falls back to its ordinal.
    expect(built.locationMap.navigationUnit[0]).toEqual({
      startPosition: 100,
      label: 'vii',
      page: 1
    })
    expect(built.locationMap.navigationUnit.at(-1)!.page).toBe(10)

    expect(built.toc).toEqual([
      { label: 'Cover', positionId: 0, page: 1, depth: 0 },
      { label: 'Part One', positionId: 1000, page: 1, depth: 0 },
      { label: 'Chapter 1', positionId: 1000, page: 1, depth: 1 },
      { label: 'Chapter 2', positionId: 4500, page: 4, depth: 1 },
      { label: 'Acknowledgements', positionId: 9500, page: 10, depth: 0 }
    ])

    expect(built.nav).toEqual({
      startPosition: 0,
      endPosition: 9999,
      startContentPosition: 0,
      startContentPage: 1,
      // Acknowledgements at the very end are back matter, not content.
      endContentPosition: 9500,
      endContentPage: 10,
      totalNumPages: 10,
      totalNumContentPages: 10
    })
  })

  it('prefers the cold-open metadata and drops what must not be stored', () => {
    const built = buildBookMetadata({
      asin: ASIN,
      renders: [fullRender],
      yjMetadata: `loadMetadata(${JSON.stringify({
        asin: ASIN,
        title: 'The Real Title',
        cpr: 'secret',
        authorsList: ['Doe, Jane:'],
        publisher: 'Pub',
        startPosition: 1000,
        endPosition: 9999
      })});`,
      startReading: {
        deliveredAsin: ASIN,
        karamelToken: 'token',
        metadataUrl: 'https://example.com',
        YJFormatVersion: 'v',
        srl: 1000
      }
    })

    expect(built.meta).toEqual({
      asin: ASIN,
      title: 'The Real Title',
      publisher: 'Pub',
      startPosition: 1000,
      endPosition: 9999,
      authorList: ['Jane Doe']
    })
    expect(built.info).toEqual({ deliveredAsin: ASIN, srl: 1000 })
    expect(built.nav.startContentPosition).toBe(1000)
    expect(built.nav.startContentPage).toBe(1)
  })

  it('ignores cold-open metadata for another book', () => {
    const built = buildBookMetadata({
      asin: ASIN,
      renders: [fullRender],
      yjMetadata: { asin: 'B0OTHER', title: 'Recommended' }
    })

    expect(built.meta.title).toBe('A Test Book')
  })

  it('holds a TOC back until a location map can give it pages', () => {
    const built = buildBookMetadata({
      asin: ASIN,
      renders: [
        render({ toc: [{ label: 'Too Early', tocPositionId: 0 }] }),
        render({ locationMap, metadata: renderMetadata }),
        render({ toc }),
        // The first TOC recorded is kept.
        render({ toc: [{ label: 'Too Late', tocPositionId: 0 }] })
      ]
    })

    expect(built.toc.map((item) => item.label)).toEqual([
      'Cover',
      'Part One',
      'Chapter 1',
      'Chapter 2',
      'Acknowledgements'
    ])
  })

  it('counts locations as pages when the book has no page numbers', () => {
    const built = buildBookMetadata({
      asin: ASIN,
      renders: [
        render({
          locationMap: { locations: [0, 10, 20, 30] },
          metadata: renderMetadata
        })
      ]
    })

    expect(built.locationMap.navigationUnit).toEqual([
      { startPosition: 0, label: '1', page: 1 },
      { startPosition: 10, label: '2', page: 2 },
      { startPosition: 20, label: '3', page: 3 },
      { startPosition: 30, label: '4', page: 4 }
    ])
    // No toc.json at all: a single "Start" entry stands in for one.
    expect(built.toc).toEqual([
      { label: 'Start', positionId: 0, page: 1, depth: 0 }
    ])
    expect(built.nav.totalNumContentPages).toBe(4)
  })

  it('skips a render whose files do not parse', () => {
    const built = buildBookMetadata({
      asin: ASIN,
      renders: [
        { toc: '{not json', locationMap: '', metadata: null },
        fullRender
      ]
    })

    expect(built.nav.totalNumPages).toBe(10)
  })

  it('refuses a book the reader never described', () => {
    expect(() =>
      buildBookMetadata({
        asin: ASIN,
        renders: [render({ metadata: renderMetadata })]
      })
    ).toThrow('expected book location map to be initialized')
  })

  // The render files of a real capture, when this checkout has one lying
  // around (they are copyrighted, so never committed). The stored metadata was
  // written by the capture's own network handlers, so the pure rebuild must
  // agree with it field for field.
  const realBookDir = path.join('out', 'B005GFBNSW')
  const realRenderDir = path.join(realBookDir, 'data', 'render')
  it.skipIf(!fs.existsSync(realRenderDir))(
    'rebuilds a real capture exactly',
    () => {
      const read = (dir: string, name: string) => {
        try {
          return fs.readFileSync(path.join(dir, name), 'utf8')
        } catch {
          return undefined
        }
      }
      const renders = fs
        .readdirSync(realRenderDir)
        .map((name) => path.join(realRenderDir, name))
        // Arrival order, as near as the directory can tell.
        .toSorted((a, b) => fs.statSync(a).mtimeMs - fs.statSync(b).mtimeMs)
        .map((dir) => ({
          toc: read(dir, 'toc.json'),
          locationMap: read(dir, 'location_map.json'),
          metadata: read(dir, 'metadata.json')
        }))
      const stored = JSON.parse(
        fs.readFileSync(path.join(realBookDir, 'metadata.json'), 'utf8')
      ) as BookMetadata

      const built = buildBookMetadata({ asin: 'B005GFBNSW', renders })

      expect(built.meta).toEqual(stored.meta)
      expect(built.info).toEqual(stored.info)
      expect(built.toc).toEqual(stored.toc)
      expect(built.locationMap).toEqual(stored.locationMap)
      expect(built.nav).toEqual(stored.nav)
    }
  )
})

describe('pageForPosition', () => {
  const map = {
    navigationUnit: [
      { startPosition: 100, label: '1', page: 1 },
      { startPosition: 200, label: '2', page: 2 }
    ]
  }

  it('finds the page a position falls on', () => {
    expect(pageForPosition(map, 0)).toBe(1)
    expect(pageForPosition(map, 199)).toBe(1)
    expect(pageForPosition(map, 200)).toBe(2)
    expect(pageForPosition(map, 10_000)).toBe(2)
  })

  it('is -1 before any location map has arrived', () => {
    expect(pageForPosition(undefined, 150)).toBe(-1)
  })

  it('maps footer locations through the location map', () => {
    expect(normalizePageNumber({ page: 7, total: 9 }, map, 3)).toBe(7)
    expect(normalizePageNumber({ location: 250, total: 9 }, map, 3)).toBe(2)
    expect(normalizePageNumber(undefined, map, 3)).toBe(3)
  })
})
