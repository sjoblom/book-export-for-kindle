import type {
  AmazonRenderLocationMap,
  BookMetadata,
  CaptureStopReason,
  ContentChunk,
  ContentStore,
  OcrLine,
  PageNav
} from '../types'
import { renderBookMarkdown } from '../book-markdown'
import { pdfDocument } from '../book-pdf'
import { bookCompleteness } from '../capture-status'
import {
  chevronClickTimeoutMs,
  type FooterPosition,
  isOnLastNumberedPage,
  isStall,
  maxNavigationAttempts,
  type NavigationAttemptInput,
  type NavigationEvidence,
  navigationResult,
  navigationTimeoutMs,
  type RecoveryInput,
  resumeScreenDecision,
  type ResumeScreenInput,
  shouldRecover,
  shouldStopBeforeCapture,
  shouldStopCapture
} from '../capture-termination'
import { parseLibraryPage } from '../library-page'
import { pageTextFromLines, tocLabelsForChunks } from '../page-text'
import { parsePageNav } from '../playwright-utils'
import { normalizeAuthors } from '../pure-utils'
import {
  buildBookMetadata,
  type BuildBookMetadataInput,
  normalizePageNumber,
  pageForPosition
} from '../render-metadata'
import { selectReusableChunks } from '../reusable-chunks'

/**
 * The pure half of book-export, for the native macOS app.
 *
 * Bundled by `pnpm build:core` into `dist-core/kindle-core.js`, which the app
 * runs in JavaScriptCore so that it captures, transcribes and exports by the
 * same rules as the CLI instead of a Swift copy of them that would drift. See
 * macos/PLAN.md for the contract.
 *
 * Everything here crosses the bridge as JSON, which has `null` but no
 * `undefined`. So arguments are read with `null` meaning "absent", and a
 * function whose TypeScript original returns `undefined` returns `null`. The
 * modules behind it may use nothing a bare JavaScriptCore context lacks — no
 * Node, no timers, no `TextEncoder`, no `console` — which the core test checks
 * by running the bundle in an empty `node:vm` context.
 */

/** `null` from JSON read as the `undefined` the TypeScript side expects. */
function opt<T>(value: T | null | undefined): T | undefined {
  return value === null ? undefined : value
}

function pageNavFromJson(pageNav: PageNav | null | undefined) {
  if (!pageNav) return undefined
  return {
    page: opt(pageNav.page),
    location: opt(pageNav.location),
    total: pageNav.total
  } as PageNav
}

type LocationMapJson = Pick<AmazonRenderLocationMap, 'navigationUnit'> | null

type ChunksJson = ContentStore | ContentChunk[] | null

const KindleCore = {
  buildBookMetadata(input: BuildBookMetadataInput) {
    return buildBookMetadata({
      asin: input.asin,
      renders: input.renders ?? [],
      yjMetadata: opt(input.yjMetadata),
      startReading: opt(input.startReading)
    })
  },

  pageForPosition(locationMap: LocationMapJson, position: number): number {
    return pageForPosition(opt(locationMap), position)
  },

  parsePageNav(footerText: string | null): PageNav | null {
    return parsePageNav(footerText) ?? null
  },

  normalizePageNumber(
    pageNav: PageNav | null,
    locationMap: LocationMapJson,
    fallbackPage: number
  ): number {
    return normalizePageNumber(
      pageNavFromJson(pageNav),
      opt(locationMap),
      fallbackPage
    )
  },

  isOnLastNumberedPage(position: FooterPosition): boolean {
    return isOnLastNumberedPage({
      value: opt(position.value),
      total: position.total
    })
  },

  maxNavigationAttempts(onLastNumberedPage: boolean): number {
    return maxNavigationAttempts(onLastNumberedPage)
  },

  chevronClickTimeoutMs(onLastNumberedPage: boolean): number {
    return chevronClickTimeoutMs(onLastNumberedPage)
  },

  navigationTimeoutMs(input: {
    onLastNumberedPage: boolean
    clickFailed: boolean
  }): number {
    return navigationTimeoutMs(input)
  },

  shouldStopBeforeCapture(input: {
    hasPageNav: boolean
    currentPage: number
    totalContentPages: number
  }) {
    return shouldStopBeforeCapture(input) ?? null
  },

  navigationResult(input: NavigationEvidence) {
    return navigationResult(input)
  },

  shouldStopCapture(input: NavigationAttemptInput) {
    return shouldStopCapture(input)
  },

  shouldRecover(input: RecoveryInput) {
    return shouldRecover(input)
  },

  resumeScreenDecision(input: ResumeScreenInput) {
    return resumeScreenDecision(input)
  },

  isStall(reason: CaptureStopReason): boolean {
    return isStall(reason)
  },

  pageTextFromLines(lines: OcrLine[], tocLabelToStrip?: string | null) {
    return pageTextFromLines(lines, opt(tocLabelToStrip))
  },

  tocLabelsForChunks(
    metadata: Pick<BookMetadata, 'pages' | 'toc'>,
    chunks: Pick<ContentChunk, 'index' | 'page'>[]
  ): Array<string | null> {
    return tocLabelsForChunks(metadata, chunks)
  },

  selectReusableChunks(
    store: ContentStore | null,
    metadata: Pick<BookMetadata, 'pages' | 'captureId'>
  ): ContentChunk[] {
    return selectReusableChunks(opt(store), {
      pages: metadata.pages,
      captureId: opt(metadata.captureId)
    })
  },

  bookCompleteness(input: {
    metadata?: BookMetadata | null
    content?: ContentStore | null
    asin?: string | null
  }) {
    return bookCompleteness({
      metadata: opt(input.metadata),
      content: opt(input.content),
      asin: opt(input.asin)
    })
  },

  /**
   * `content` is the store from `content.json` (its capture id is checked),
   * or bare chunks taken to be from this capture.
   */
  renderMarkdown(metadata: BookMetadata, content: ChunksJson) {
    return renderBookMarkdown(metadata, content)
  },

  /** `content` as for `renderMarkdown`. */
  pdfDocument(metadata: BookMetadata, content: ChunksJson) {
    return pdfDocument(metadata, content)
  },

  parseLibraryPage(payload: unknown) {
    return parseLibraryPage(payload)
  },

  normalizeAuthors(authors: string[]): string[] {
    return normalizeAuthors(authors)
  }
}

export type KindleCoreApi = typeof KindleCore

;(globalThis as { KindleCore?: KindleCoreApi }).KindleCore = KindleCore
