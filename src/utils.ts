import fs from 'node:fs/promises'
import path from 'node:path'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'

import hashObjectImpl from 'hash-object'
import sortKeys from 'sort-keys'
import { extract } from 'tar'
import { temporaryDirectory } from 'tempy'

import type { BookMetadata } from './types'

export function assert(
  value: unknown,
  message?: string | Error
): asserts value {
  if (value) {
    return
  }

  if (!message) {
    throw new Error('Assertion failed')
  }

  throw typeof message === 'string' ? new Error(message) : message
}

export function isPositiveInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value > 0
}

export function getEnv(name: string): string | undefined {
  try {
    return typeof process !== 'undefined'
      ? // eslint-disable-next-line no-process-env
        process.env?.[name]
      : undefined
  } catch {
    return undefined
  }
}

/**
 * Amazon's `"Last, First:Last2, First2:"` author strings as display names.
 *
 * Safe to apply twice: stored metadata holds already-normalized names, and
 * readers such as the web app's book list normalize again on the way out —
 * a name with no comma is taken as already in display order.
 */
export function normalizeAuthors(rawAuthors: string[]): string[] {
  if (!rawAuthors?.length) {
    return []
  }

  const names = rawAuthors.flatMap((raw) => raw.split(':')).filter(Boolean)

  return Array.from(new Set(names), (name) =>
    name.includes(',')
      ? name
          .split(',')
          .map((part) => part.trim())
          .toReversed()
          .join(' ')
      : name.trim()
  )
}

/**
 * Escape a string for literal use inside a RegExp.
 *
 * Book metadata is full of strings that are also regex syntax — a TOC label
 * like "C++ Primer" is a syntax error, and "Chapter 1 (cont.)" quietly matches
 * something other than itself.
 */
export function escapeRegExp(str: string): string {
  return str.replaceAll(/[$()*+.?[\\\]^{|}]/g, String.raw`\$&`)
}

const JSONP_REGEX = /\(({.*})\)/

export function parseJsonpResponse<T = unknown>(body: string): T | undefined {
  const content = body?.match(JSONP_REGEX)?.[1]
  if (!content) {
    return
  }

  try {
    return JSON.parse(content) as T
  } catch {
    return
  }
}
const numerals = { I: 1, V: 5, X: 10, L: 50, C: 100, D: 500, M: 1000 }

export function deromanize(romanNumeral: string): number {
  const roman = romanNumeral.toUpperCase().split('')
  let num = 0
  let val = 0

  while (roman.length) {
    val = numerals[roman.shift()! as keyof typeof numerals]
    num += val * (val < numerals[roman[0] as keyof typeof numerals] ? -1 : 1)
  }

  return num
}

export function hashObject(obj: Record<string, any>): string {
  return hashObjectImpl(obj, {
    algorithm: 'sha1',
    encoding: 'hex'
  })
}

/**
 * Decompress a TAR (optionally .tar.gz/.tgz) Buffer to a fresh temp directory.
 * Returns the absolute path of the temp directory.
 */
export async function extractTar(
  buf: Buffer,
  {
    strip = 0,
    cwd = temporaryDirectory()
  }: { strip?: number; cwd?: string } = {}
): Promise<string> {
  const isGzip = buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b

  try {
    const extractor = extract({
      cwd,
      gzip: isGzip,
      strip
    })

    await pipeline(Readable.from(buf), extractor)
    return cwd
  } catch (err) {
    // Clean up the temp dir if extraction fails
    await fs.rm(cwd, { recursive: true, force: true }).catch(() => {})
    throw err
  }
}

export async function readJsonFile<T = unknown>(filePath: string): Promise<T> {
  return JSON.parse(await fs.readFile(filePath, 'utf8')) as T
}

export async function tryReadJsonFile<T = unknown>(
  filePath: string
): Promise<T | undefined> {
  try {
    return await readJsonFile(filePath)
  } catch {}
}

/** The directory holding a book's page images, inside its own directory. */
export const PAGE_IMAGES_DIR = 'pages'

/**
 * Turn a stored `screenshot` path into one that can actually be opened.
 *
 * Captures now store `pages/000-001.png`, relative to the book directory, so
 * the output tree survives being moved and so transcription run from another
 * working directory finds the images. Two older forms are still on disk: an
 * absolute path, and whatever relative path the caller passed to capture —
 * usually `out/<asin>/pages/000-001.png`, which only resolves from the
 * directory that capture ran in. Without this, running OCR from elsewhere
 * failed with the thoroughly misleading "page images are gone (cleaned up)".
 */
export function resolveScreenshotPath(
  bookDir: string,
  screenshot: string
): string {
  if (path.isAbsolute(screenshot)) return screenshot

  const [first] = screenshot.split(/[/\\]/)
  if (first === PAGE_IMAGES_DIR) return path.join(bookDir, screenshot)

  // An older path, relative to a working directory we can only assume was
  // this one. Nothing better is recoverable from the string itself.
  return screenshot
}

const bookMetadataFieldOrder: (keyof BookMetadata)[] = [
  'meta',
  'info',
  'nav',
  'captureId',
  'capture',
  'toc',
  'pages',
  'locationMap'
]

const bookMetadataFieldsOrderMap = Object.fromEntries(
  bookMetadataFieldOrder.map((f, i) => [f, i])
)

function bookMetadataFieldComparator(a: string, b: string): number {
  const aIndex = bookMetadataFieldsOrderMap[a] ?? Infinity
  const bIndex = bookMetadataFieldsOrderMap[b] ?? Infinity

  return aIndex - bIndex
}
export function normalizeBookMetadata(
  book: Partial<BookMetadata>
): Partial<BookMetadata> {
  return sortKeys(book, { compare: bookMetadataFieldComparator })
}
