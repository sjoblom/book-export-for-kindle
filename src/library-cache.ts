import fs from 'node:fs/promises'
import path from 'node:path'

import { type LibraryBook, safeCoverUrl } from './kindle-library'
import { tryReadJsonFile } from './utils'

/**
 * The last Kindle library the web app fetched, kept on disk.
 *
 * Reading the library means starting Chrome and asking Amazon, which takes a
 * while; showing the list from the previous launch straight away and refreshing
 * it in the background makes the app feel instant after the first run.
 *
 * The file lives inside the browser profile directory rather than the output
 * folder. The library belongs to whichever Amazon account is signed in to that
 * profile, so the two should come and go together: signing in with another
 * account overwrites it on the next refresh, and deleting the profile to sign
 * out takes the cached book list with it. The output folder, by contrast, is
 * a user-visible folder full of exports that may be synced or shared. Chrome
 * leaves unknown files at the top of its profile alone.
 */

const CACHE_FILE = 'kindle-export-library.json'
const CACHE_VERSION = 1

/** A cache with more books than this is not one we wrote. */
const MAX_CACHED_BOOKS = 5000

const ASIN_REGEX = /^[A-Z0-9]{1,20}$/

export interface CachedLibrary {
  books: LibraryBook[]
  fetchedAt: number
}

export function libraryCachePath(profileDir: string): string {
  return path.join(profileDir, CACHE_FILE)
}

/**
 * The cached library, or `undefined` when there is none or it can't be
 * trusted. Every entry is re-validated: the page renders these titles and
 * cover URLs, and the file is only as trustworthy as whatever last wrote it.
 */
export async function readLibraryCache(
  profileDir: string
): Promise<CachedLibrary | undefined> {
  const raw = await tryReadJsonFile<Record<string, unknown>>(
    libraryCachePath(profileDir)
  )
  if (!raw || typeof raw !== 'object' || raw.version !== CACHE_VERSION) return
  if (typeof raw.fetchedAt !== 'number' || !Array.isArray(raw.books)) return
  if (raw.books.length > MAX_CACHED_BOOKS) return

  const books: LibraryBook[] = []
  for (const entry of raw.books as unknown[]) {
    if (!entry || typeof entry !== 'object') continue

    const book = entry as Record<string, unknown>
    if (typeof book.asin !== 'string' || !ASIN_REGEX.test(book.asin)) continue

    books.push({
      asin: book.asin,
      title: typeof book.title === 'string' ? book.title : book.asin,
      authors: Array.isArray(book.authors)
        ? book.authors.filter((a): a is string => typeof a === 'string')
        : [],
      resourceType:
        typeof book.resourceType === 'string' ? book.resourceType : undefined,
      percentageRead:
        typeof book.percentageRead === 'number'
          ? book.percentageRead
          : undefined,
      coverUrl: safeCoverUrl(book.coverUrl)
    })
  }

  return { books, fetchedAt: raw.fetchedAt }
}

/**
 * Store the library for the next launch. Failing to write it only costs the
 * next launch its head start, so errors are swallowed rather than surfaced.
 */
export async function writeLibraryCache(
  profileDir: string,
  library: CachedLibrary
): Promise<void> {
  try {
    await fs.mkdir(profileDir, { recursive: true })
    const target = libraryCachePath(profileDir)
    // Written aside and renamed into place, so a crash mid-write leaves the
    // previous list rather than a truncated file.
    const temp = `${target}.${process.pid}.tmp`
    // A reading list is personal, like everything else in the profile.
    await fs.writeFile(
      temp,
      JSON.stringify({ version: CACHE_VERSION, ...library }),
      { mode: 0o600 }
    )
    await fs.rename(temp, target)
  } catch {
    // See above: the cache is an optimisation.
  }
}
