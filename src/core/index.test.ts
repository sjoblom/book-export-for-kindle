import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import vm from 'node:vm'

import { beforeAll, describe, expect, it } from 'vitest'

import type { BookMetadata, ContentChunk } from '../types'
import { renderBookMarkdown } from '../book-markdown'
import { buildBookMetadata } from '../render-metadata'

/**
 * The bundle the native app runs, run the way the app runs it.
 *
 * JavaScriptCore gives a script the language and nothing else: no `require`,
 * `process`, `console`, timers, `TextEncoder` or `URL`. An empty `node:vm`
 * context is the same environment, so a module that reaches for any of those
 * fails here rather than inside the app. Every call goes through JSON strings
 * exactly as `JSCore.call` passes them.
 */

let bundle: string

beforeAll(() => {
  // Built from the real config into a scratch directory, so the test checks
  // what `pnpm build:core` ships without touching dist-core.
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kindle-core-'))
  try {
    execFileSync(
      path.join('node_modules', '.bin', 'tsup'),
      ['--config', 'tsup.core.config.ts', '--out-dir', outDir, '--silent'],
      { stdio: 'pipe' }
    )
    bundle = fs.readFileSync(path.join(outDir, 'kindle-core.js'), 'utf8')
  } finally {
    fs.rmSync(outDir, { recursive: true, force: true })
  }
}, 60_000)

function loadCore() {
  const context = vm.createContext({})
  vm.runInContext(bundle, context, { filename: 'kindle-core.js' })

  return {
    names: vm.runInContext('Object.keys(KindleCore)', context) as string[],
    call(name: string, ...args: unknown[]): unknown {
      context.__name = name
      context.__args = JSON.stringify(args)
      const raw = vm.runInContext(
        'KindleCore[__name](...JSON.parse(__args))',
        context
      ) as unknown
      assertJsonValue(raw, name)
      return JSON.parse(
        vm.runInContext(
          'JSON.stringify(KindleCore[__name](...JSON.parse(__args)))',
          context
        ) as string
      )
    }
  }
}

/**
 * Fails on anything that doesn't survive `JSON.stringify` as itself. Object
 * properties may be `undefined` (they are simply absent in JSON), a whole
 * result may not.
 */
function assertJsonValue(value: unknown, where: string, isProperty = false) {
  if (value === undefined) {
    if (isProperty) return
    throw new Error(`${where} is undefined`)
  }
  if (value === null) return
  switch (typeof value) {
    case 'string':
    case 'boolean':
      return
    case 'number':
      if (!Number.isFinite(value)) throw new Error(`${where} is ${value}`)
      return
    case 'object':
      break
    default:
      throw new Error(`${where} is a ${typeof value}`)
  }

  // Objects from the vm context have that context's prototypes, so they are
  // told apart by tag rather than `instanceof`.
  const tag = Object.prototype.toString.call(value)
  if (tag === '[object Array]') {
    for (const [i, item] of (value as unknown[]).entries()) {
      assertJsonValue(item, `${where}[${i}]`)
    }
    return
  }
  if (tag !== '[object Object]') throw new Error(`${where} is a ${tag}`)
  const proto = Object.getPrototypeOf(value)
  if (proto !== null && Object.getPrototypeOf(proto) !== null) {
    throw new Error(`${where} is a class instance`)
  }
  for (const [key, item] of Object.entries(value)) {
    assertJsonValue(item, `${where}.${key}`, true)
  }
}

const locationMapText = JSON.stringify({
  locations: [0, 10],
  navigationUnit: [
    { startPosition: 0, label: '1' },
    { startPosition: 100, label: '2' },
    { startPosition: 200, label: '3' }
  ]
})

const renders = [
  {
    locationMap: locationMapText,
    metadata: JSON.stringify({
      bookTitle: 'Core Book',
      authors: ['Doe, Jane'],
      lang: 'en',
      firstPositionId: 0,
      lastPositionId: 299,
      srl: 0
    }),
    toc: JSON.stringify([
      { label: 'One', tocPositionId: 0 },
      { label: 'Two', tocPositionId: 100 }
    ])
  }
]

function chunk(index: number, text: string): ContentChunk {
  return { index, page: index + 1, text, screenshot: `pages/00${index}.png` }
}

const metadata: BookMetadata = {
  ...buildBookMetadata({ asin: 'B0CORE', renders }),
  captureId: 'capture-1',
  capture: {
    complete: true,
    reason: 'end-of-book',
    lastPage: 3,
    totalContentPages: 3
  },
  pages: [0, 1, 2].map((index) => ({
    index,
    page: index + 1,
    screenshot: `pages/00${index}.png`
  }))
}

const store = {
  captureId: 'capture-1',
  chunks: [
    chunk(0, 'Opening words.'),
    {
      ...chunk(1, 'stale'),
      lines: [
        // A centred heading, so it reads as its own paragraph: only a whole
        // heading line is taken off, never the start of the prose.
        { text: 'Two', left: 400, top: 60, width: 100, height: 30 },
        { text: 'A line that', left: 40, top: 100, width: 820, height: 30 },
        { text: 'wraps on.', left: 40, top: 145, width: 300, height: 30 }
      ]
    },
    chunk(2, 'The end.')
  ]
}

describe('kindle-core.js', () => {
  it('uses nothing a bare JavaScriptCore context lacks', () => {
    expect(bundle).not.toMatch(
      /\b(require|process|Buffer|TextEncoder|TextDecoder|console|setTimeout|setInterval|import\.meta)\b/
    )
  })

  it('answers every KindleCore call with plain JSON', () => {
    const core = loadCore()
    const calls: Record<string, () => void> = {
      buildBookMetadata: () => {
        const input = { asin: 'B0CORE', renders, yjMetadata: null }
        expect(core.call('buildBookMetadata', input)).toEqual(
          buildBookMetadata({ asin: 'B0CORE', renders })
        )
      },
      pageForPosition: () => {
        expect(core.call('pageForPosition', metadata.locationMap, 150)).toBe(2)
        expect(core.call('pageForPosition', null, 150)).toBe(-1)
      },
      parsePageNav: () => {
        expect(core.call('parsePageNav', 'Page 3 of 10')).toEqual({
          page: 3,
          total: 10
        })
        expect(core.call('parsePageNav', 'Location xii of 10')).toBeNull()
        expect(core.call('parsePageNav', null)).toBeNull()
      },
      normalizePageNumber: () => {
        expect(
          core.call(
            'normalizePageNumber',
            { page: null, location: 150, total: 300 },
            metadata.locationMap,
            9
          )
        ).toBe(2)
        expect(core.call('normalizePageNumber', null, null, 9)).toBe(9)
      },
      isOnLastNumberedPage: () => {
        expect(
          core.call('isOnLastNumberedPage', { value: 10, total: 10 })
        ).toBe(true)
        expect(
          core.call('isOnLastNumberedPage', { value: null, total: 10 })
        ).toBe(false)
      },
      maxNavigationAttempts: () => {
        expect(core.call('maxNavigationAttempts', false)).toBe(5)
      },
      chevronClickTimeoutMs: () => {
        expect(core.call('chevronClickTimeoutMs', false)).toBe(5000)
      },
      navigationTimeoutMs: () => {
        expect(
          core.call('navigationTimeoutMs', {
            onLastNumberedPage: false,
            clickFailed: true
          })
        ).toBe(1000)
      },
      shouldStopBeforeCapture: () => {
        expect(
          core.call('shouldStopBeforeCapture', {
            hasPageNav: true,
            currentPage: 2,
            totalContentPages: 3
          })
        ).toBeNull()
        expect(
          core.call('shouldStopBeforeCapture', {
            hasPageNav: false,
            currentPage: 2,
            totalContentPages: 3
          })
        ).toEqual({ type: 'stop', complete: false, reason: 'no-page-nav' })
      },
      shouldStopCapture: () => {
        expect(
          core.call('shouldStopCapture', {
            observations: ['navigated'],
            onLastNumberedPage: false,
            maxAttempts: 5
          })
        ).toEqual({ type: 'capture-next-screen' })
      },
      shouldRecover: () => {
        expect(
          core.call('shouldRecover', {
            reason: 'navigation-failed',
            page: 2,
            recoveries: []
          })
        ).toEqual({ type: 'recover' })
      },
      resumeScreenDecision: () => {
        expect(
          core.call('resumeScreenDecision', {
            resume: { page: 2, skipped: 0 },
            alreadyCaptured: true,
            currentPage: 2,
            capturedAny: true
          })
        ).toEqual({ type: 'skip' })
      },
      isStall: () => {
        expect(core.call('isStall', 'end-of-book')).toBe(false)
      },
      pageTextFromLines: () => {
        expect(
          core.call('pageTextFromLines', store.chunks[1]!.lines, 'Two')
        ).toBe('A line that wraps on.')
        expect(core.call('pageTextFromLines', [], null)).toBe('')
      },
      tocLabelsForChunks: () => {
        expect(
          core.call('tocLabelsForChunks', metadata, [
            { index: 0, page: 1 },
            { index: 1, page: 2 }
          ])
        ).toEqual([null, 'Two'])
      },
      selectReusableChunks: () => {
        expect(core.call('selectReusableChunks', store, metadata)).toHaveLength(
          3
        )
        expect(core.call('selectReusableChunks', null, metadata)).toEqual([])
      },
      bookCompleteness: () => {
        expect(
          core.call('bookCompleteness', {
            metadata,
            content: store,
            asin: null
          })
        ).toMatchObject({ complete: true, transcribedPages: 3 })
      },
      renderMarkdown: () => {
        const rendered = core.call('renderMarkdown', metadata, store) as {
          fileName: string
          markdown: string
        }
        expect(rendered).toEqual(renderBookMarkdown(metadata, store))
        expect(rendered.fileName).toBe('core_book.md')
        // Rebuilt from the kept lines, with the TOC heading stripped.
        expect(rendered.markdown).toContain('A line that wraps on.')
        expect(rendered.markdown).not.toContain('stale')
      },
      pdfDocument: () => {
        expect(core.call('pdfDocument', metadata, store.chunks)).toEqual({
          title: 'Core Book',
          authors: ['Jane Doe'],
          sections: [
            { label: 'One', depth: 0, text: 'Opening words.' },
            {
              label: 'Two',
              depth: 0,
              text: 'A line that wraps on.\n\nThe end.'
            }
          ]
        })
      },
      parseLibraryPage: () => {
        expect(
          core.call('parseLibraryPage', {
            itemsList: [
              {
                asin: 'b0core',
                title: 'Core Book',
                authors: ['Doe, Jane:'],
                productUrl: 'https://m.media-amazon.com/images/I/x.jpg'
              },
              {
                asin: 'B0EVIL',
                productUrl: 'https://user@m.media-amazon.com/x.jpg'
              }
            ],
            paginationToken: 'next'
          })
        ).toEqual({
          books: [
            {
              asin: 'B0CORE',
              title: 'Core Book',
              authors: ['Jane Doe'],
              // No `URL` in JavaScriptCore: the hand parse must still accept
              // Amazon's covers and refuse credentials.
              coverUrl: 'https://m.media-amazon.com/images/I/x.jpg'
            },
            { asin: 'B0EVIL', title: 'B0EVIL', authors: [] }
          ],
          paginationToken: 'next'
        })
      },
      normalizeAuthors: () => {
        expect(core.call('normalizeAuthors', ['Doe, Jane:Roe, Rick:'])).toEqual(
          ['Jane Doe', 'Rick Roe']
        )
      }
    }

    // A function added to KindleCore without a call here fails the test, so
    // the whole surface stays covered.
    expect(core.names.toSorted()).toEqual(Object.keys(calls).toSorted())
    for (const run of Object.values(calls)) run()
  })
})
