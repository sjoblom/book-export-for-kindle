/**
 * Rebuilding paragraphs from the line boxes an OCR engine reports.
 *
 * Apple's Vision framework recognises one *rendered* line at a time, but the
 * formatter downstream (`postprocess-text.ts`) treats every newline in a page's
 * text as a paragraph boundary. Emitting one line per newline therefore turns
 * every wrapped line of prose into its own paragraph. This module puts the
 * paragraphs back together from where the lines sit on the page, so the engine
 * can honour that contract: one newline out means one paragraph.
 *
 * Every threshold below is calibrated from the page itself — the median line
 * height, the median line pitch, the column edges — because font size, leading
 * and margins all change with the reader's own settings.
 */

import type { OcrLine } from './types'

export type { OcrLine } from './types'

interface PageMetrics {
  /** Typical height of a line's box, which stands in for the font size. */
  lineHeight: number
  /** Typical top-to-top distance between consecutive lines. */
  pitch: number
  /** Where the body column starts, ignoring indented and centred lines. */
  columnLeft: number
  /** Where the body column ends, taken from the line that reaches furthest. */
  columnRight: number
}

/**
 * A hyphen or dash at the end of a line. Whether it is part of the word or a
 * typesetter's break is not something the layout can tell (see
 * `joinWrappedLines`), so the two are treated alike.
 */
const HYPHEN_END_REGEX = /[-‐—–]$/u

function percentile(sorted: number[], fraction: number): number {
  const index = (sorted.length - 1) * fraction
  const lower = Math.floor(index)
  const upper = Math.ceil(index)
  if (lower === upper) return sorted[lower]!

  return sorted[lower]! + (sorted[upper]! - sorted[lower]!) * (index - lower)
}

function quantile(values: number[], fraction: number): number {
  return percentile(
    values.toSorted((a, b) => a - b),
    fraction
  )
}

function measurePage(lines: OcrLine[]): PageMetrics {
  const lineHeight = quantile(
    lines.map((line) => line.height),
    0.5
  )

  // Only forward steps down the page describe leading; Vision occasionally
  // hands back two boxes on the same visual line, and those would drag the
  // typical pitch towards zero.
  const pitches: number[] = []
  for (let i = 1; i < lines.length; i++) {
    const step = lines[i]!.top - lines[i - 1]!.top
    if (step > 0) pitches.push(step)
  }

  // Leading is never as much as the font size again, so a step of more than
  // two line heights can only be a paragraph gap (or a heading's space). Those
  // are left out before taking the median: on a page of three lines with one
  // gap, the gap is half the steps and would otherwise drag the typical pitch
  // up far enough to hide itself. The median of what is left, rather than a
  // low quantile, is still the right estimate, because Vision's box tops
  // jitter and a low quantile picks the tightest pair and splits full pages.
  const bodySteps = pitches.filter((step) => step <= lineHeight * 2)

  return {
    lineHeight,
    pitch: bodySteps.length ? quantile(bodySteps, 0.5) : lineHeight * 1.2,
    // Everything that is not flush left — indented first lines, centred
    // headings — sits to the right of the column edge, so a low quantile finds
    // the edge itself. The median would do on a page of prose but drifts on a
    // short page that is half heading.
    columnLeft: quantile(
      lines.map((line) => line.left),
      0.25
    ),
    // Right edges are the other way round: every paragraph ends on a short
    // line, so only the longest line reaches the margin. Being too generous
    // here is the safe direction — it can only make the `stops short` test
    // below more permissive, and that test never splits a paragraph on its own.
    columnRight: Math.max(...lines.map((line) => line.left + line.width))
  }
}

/**
 * Whether a line is centred in the column rather than set flush left, which is
 * how chapter headings, scene breaks and epigraph attributions are rendered.
 * Those should stay paragraphs of their own even when nothing else separates
 * them from the prose around them.
 */
function isCentered(line: OcrLine, metrics: PageMetrics): boolean {
  const columnWidth = metrics.columnRight - metrics.columnLeft
  if (columnWidth <= 0) return false

  // A full-width line cannot be centred, whatever its margins say.
  if (line.width > columnWidth * 0.8) return false

  const leftMargin = line.left - metrics.columnLeft
  const rightMargin = metrics.columnRight - (line.left + line.width)

  // Flush left with a ragged end is just the last line of a paragraph.
  if (leftMargin < metrics.lineHeight * 0.5) return false

  // Generous, because the column's right edge is only ever an estimate: it
  // comes from the longest line on the page, which need not quite reach the
  // margin.
  const tolerance = Math.max(metrics.lineHeight * 1.5, columnWidth * 0.06)
  return Math.abs(leftMargin - rightMargin) <= tolerance
}

/**
 * Whether `line` sits further down the page than the leading on this page
 * explains, which is how a book that separates paragraphs with a blank line
 * marks a boundary.
 *
 * The margin has to be generous because Vision's boxes hug the glyphs: a line
 * with no ascenders starts measurably lower than its neighbours, so raw
 * top-to-top distances jitter by a fair fraction of a line.
 */
function hasExtraLeading(
  prev: OcrLine,
  line: OcrLine,
  metrics: PageMetrics
): boolean {
  const step = line.top - prev.top
  const slack = Math.max(metrics.pitch * 0.35, metrics.lineHeight * 0.4)

  return step > metrics.pitch + slack
}

/**
 * Text that ends a sentence: terminal punctuation, optionally followed by the
 * quotation marks or brackets that close around it.
 */
const SENTENCE_END_REGEX = /[.!?…]["'”’)\]]*$/u

/**
 * Whether `line` is a first line indented under the previous paragraph's last
 * line, which is how a book that does not leave a blank line marks a boundary.
 *
 * An indent is about an em wide, which is why the threshold is scaled to the
 * line height rather than to the page. The previous line also has to look
 * like the end of a paragraph, which rules out prose that simply runs on with
 * a wide glyph at the start of a line. Usually that means it stopped short of
 * the right margin, but in justified text a paragraph's last line can happen
 * to fill the measure, so ending on a full stop counts too. Either alone is
 * cheap evidence; together with the indent they are rarely wrong.
 */
function isIndentedStart(
  prev: OcrLine,
  line: OcrLine,
  metrics: PageMetrics
): boolean {
  const indented = line.left > metrics.columnLeft + metrics.lineHeight * 0.8
  const prevStopsShort =
    prev.left + prev.width < metrics.columnRight - metrics.lineHeight * 0.3

  const prevEndsSentence = SENTENCE_END_REGEX.test(prev.text.trim())

  return indented && (prevStopsShort || prevEndsSentence)
}

/**
 * A drop cap as Vision reads it: one capital letter, perhaps behind an opening
 * quotation mark, on a line of its own.
 */
const DROP_CAP_TEXT_REGEX = /^["'“‘]?\p{Lu}$/u

/**
 * Whether `line` is one of those set beside a drop cap: it starts before the
 * capital's foot (with half a line of grace, since the last such line's box
 * can reach just below it) and to the right of the capital's middle.
 */
function isBesideDropCap(
  line: OcrLine,
  cap: OcrLine,
  lineHeight: number
): boolean {
  return (
    line.top < cap.top + cap.height - lineHeight * 0.5 &&
    line.left > cap.left + cap.width * 0.5
  )
}

/**
 * Fold decorative drop caps back into the words they begin.
 *
 * A chapter that opens with a large initial capital comes back from Vision as
 * a line holding just that letter (`F`) followed by the rest of the word on
 * the first real line (`antasies give us…`). Left alone that is a one-letter
 * paragraph and a broken word. The capital is also several lines tall and the
 * lines beside it are pushed right to wrap around it, so it would skew the
 * page's line height and make those wrapped lines look indented.
 *
 * A drop cap is recognised by all of: a single capital, a box more than one
 * and a half lines tall, and a next line that starts in lowercase beside it —
 * the tail of the same word. That leaves alone a real one-letter line such as
 * a section label, which is neither tall nor followed by half a word. The
 * letter is prefixed to that line with no space. The lines wrapped beside the
 * capital are moved out together until the leftmost of them meets the
 * capital's left edge, which is where the column really starts; moving them
 * as a block rather than each to the edge keeps an indent among them, since a
 * short opening paragraph can end and the next begin before the capital does.
 */
function absorbDropCaps(lines: OcrLine[]): OcrLine[] {
  const lineHeight = quantile(
    lines.map((line) => line.height),
    0.5
  )
  const result: OcrLine[] = []

  for (let i = 0; i < lines.length; i++) {
    const cap = lines[i]!
    const next = lines[i + 1]

    const isDropCap =
      next !== undefined &&
      DROP_CAP_TEXT_REGEX.test(cap.text.trim()) &&
      cap.height > lineHeight * 1.6 &&
      /^\p{Ll}/u.test(next.text.trim()) &&
      isBesideDropCap(next, cap, lineHeight)
    if (!isDropCap) {
      result.push(cap)
      continue
    }

    let end = i + 2
    while (
      end < lines.length &&
      isBesideDropCap(lines[end]!, cap, lineHeight)
    ) {
      end++
    }
    const wrapped = lines.slice(i + 1, end)
    const shift = Math.min(...wrapped.map((line) => line.left)) - cap.left

    for (const [j, line] of wrapped.entries()) {
      result.push({
        ...line,
        text: j === 0 ? cap.text.trim() + line.text.trim() : line.text,
        left: line.left - shift,
        width: line.width + shift
      })
    }
    i = end - 1
  }

  return result
}

/**
 * Join two rendered lines of the same paragraph back into running text.
 *
 * A line-ending hyphen is kept. It might be a typesetter's break in the middle
 * of a word (`some-`/`thing`) or the real hyphen of a compound (`self-`/
 * `esteem`, `well-`/`known`), and nothing visible on the page tells the two
 * apart: an earlier rule that dropped the hyphen between lowercase letters
 * turned `self-esteem` into `selfesteem`. Kept, a soft break reads as an odd
 * hyphen; dropped, a compound becomes a different word. Odd is recoverable
 * from the stored lines, and a reader can see what happened; a merged word is
 * neither.
 */
export function joinWrappedLines(prev: string, next: string): string {
  // The word after a hyphen or dash belongs tight against it, not a space away.
  if (HYPHEN_END_REGEX.test(prev)) {
    return prev + next
  }

  return `${prev} ${next}`
}

/**
 * Turn per-line OCR output into text where each newline is a real paragraph
 * boundary, which is what the markdown formatter expects.
 *
 * The lines are consumed in the order the engine reported them, which is the
 * reading order Vision already worked out; this only decides where the breaks
 * between them go.
 */
export function reconstructParagraphs(lines: OcrLine[]): string {
  const usable = absorbDropCaps(
    lines.filter((line) => line.text.trim().length > 0)
  )
  if (usable.length === 0) return ''

  const metrics = measurePage(usable)
  const paragraphs: string[] = []

  let current = usable[0]!.text.trim()
  let currentIsCentered = isCentered(usable[0]!, metrics)

  for (let i = 1; i < usable.length; i++) {
    const prev = usable[i - 1]!
    const line = usable[i]!
    const centered = isCentered(line, metrics)

    // Crossing between centred and flush-left text is always a boundary. Two
    // centred lines in a row are one wrapped heading rather than two headings,
    // and the indent test means nothing there — every centred line is indented.
    const boundary =
      centered !== currentIsCentered ||
      hasExtraLeading(prev, line, metrics) ||
      (!centered && isIndentedStart(prev, line, metrics))

    if (boundary) {
      paragraphs.push(current)
      current = line.text.trim()
    } else {
      current = joinWrappedLines(current, line.text.trim())
    }

    currentIsCentered = centered
  }

  paragraphs.push(current)
  return paragraphs.filter(Boolean).join('\n')
}

/**
 * Validate the line boxes off the wire. The worker is our own binary, but a
 * stale one on disk should degrade to dropping a line rather than throwing
 * partway through a book.
 */
export function parseOcrLines(value: unknown): OcrLine[] {
  if (!Array.isArray(value)) return []

  const lines: OcrLine[] = []
  for (const entry of value) {
    const line = entry as Partial<OcrLine> | null
    if (!line || typeof line.text !== 'string') continue
    if (
      ![line.left, line.top, line.width, line.height].every(
        (n) => typeof n === 'number' && Number.isFinite(n)
      )
    ) {
      continue
    }

    lines.push({
      text: line.text,
      left: line.left!,
      top: line.top!,
      width: line.width!,
      height: line.height!
    })
  }

  return lines
}
