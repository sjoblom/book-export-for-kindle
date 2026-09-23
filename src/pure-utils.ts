/**
 * The helpers from `utils.ts` that touch nothing but their arguments.
 *
 * Kept apart because `src/core` bundles them for JavaScriptCore, which has no
 * Node: importing `utils.ts` itself would drag in `node:fs`, tar and tempy.
 * `utils.ts` re-exports all of these, so Node-side callers need not care.
 */

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
