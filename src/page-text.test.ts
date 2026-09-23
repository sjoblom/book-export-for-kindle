import { describe, expect, it } from 'vitest'

import type { BookMetadata, ContentChunk, OcrLine } from './types'
import {
  createTocLabelResolver,
  shapePageText,
  withCurrentText
} from './page-text'

/** Two wrapped lines of one paragraph, as Vision reports a plain page. */
function oneParagraphLines(): OcrLine[] {
  return [
    {
      text: 'The first line of a paragraph that',
      left: 40,
      top: 100,
      width: 820,
      height: 30
    },
    {
      text: 'wraps onto a second line.',
      left: 40,
      top: 145,
      width: 400,
      height: 30
    }
  ]
}

const metadata: Pick<BookMetadata, 'pages' | 'toc'> = {
  toc: [{ label: 'Chapter One', positionId: 1, page: 2, depth: 0 }],
  pages: [
    { index: 0, page: 1, screenshot: 'pages/000.png' },
    { index: 1, page: 2, screenshot: 'pages/001.png' },
    // Kindle rendered book page 2 across two screens.
    { index: 2, page: 2, screenshot: 'pages/002.png' }
  ]
}

describe('shapePageText', () => {
  it('strips a page number only from the first line', () => {
    expect(shapePageText('12\nSome text.\n1984\nMore text.')).toBe(
      'Some text.\n1984\nMore text.'
    )
    expect(shapePageText('Some text.\n12\nMore.')).toBe('Some text.\n12\nMore.')
  })

  it('trims every line', () => {
    expect(shapePageText('  a  \n\t b \n')).toBe('a\nb')
  })

  it('strips the TOC label from the start of the page, case-insensitively', () => {
    expect(
      shapePageText('CHAPTER ONE\nIt began.', {
        tocLabelToStrip: 'Chapter One'
      })
    ).toBe('It began.')
    // Only at the start: the same words later on are prose.
    expect(
      shapePageText('It began in chapter one.', {
        tocLabelToStrip: 'Chapter One'
      })
    ).toBe('It began in chapter one.')
  })

  it('treats the label as literal text, not a pattern', () => {
    expect(
      shapePageText('Why? (1)\nText.', { tocLabelToStrip: 'Why? (1)' })
    ).toBe('Text.')
  })

  it('strips a heading whose case and punctuation differ from the label', () => {
    expect(
      shapePageText("DON'T THINK\nWhy scheme for a morsel?", {
        tocLabelToStrip: 'Don’t think!'
      })
    ).toBe('Why scheme for a morsel?')
    expect(
      shapePageText('i always have a thing for.….\nThe robots are lovers.', {
        tocLabelToStrip: 'i always have a thing for…'
      })
    ).toBe('The robots are lovers.')
  })

  it('strips a heading the page wraps over several lines', () => {
    expect(
      shapePageText('CHAPTER ONE\nYOU ARE NOT YOUR MIND\nThe body.', {
        tocLabelToStrip: 'Chapter One: You Are Not Your Mind'
      })
    ).toBe('The body.')
  })

  it('strips an unnumbered heading under a numbered label', () => {
    expect(
      shapePageText('The Mom Test\nTrust nobody.', {
        tocLabelToStrip: '1. The Mom Test'
      })
    ).toBe('Trust nobody.')
    // And the numbered heading, as printed.
    expect(
      shapePageText('1. The Mom Test\nTrust nobody.', {
        tocLabelToStrip: '1. The Mom Test'
      })
    ).toBe('Trust nobody.')
  })

  it('keeps prose that merely begins with the label', () => {
    // A roman-numeral chapter whose first sentence starts with the same letter.
    expect(
      shapePageText('It was a cold morning.', { tocLabelToStrip: 'I' })
    ).toBe('It was a cold morning.')
    expect(
      shapePageText('IV\nIvy grew on the walls.', { tocLabelToStrip: 'IV' })
    ).toBe('Ivy grew on the walls.')
    expect(
      shapePageText('Ivy grew on the walls.', { tocLabelToStrip: 'IV' })
    ).toBe('Ivy grew on the walls.')
    // A word label that opens an ordinary sentence.
    expect(
      shapePageText('Introduction of the new rules took a year.', {
        tocLabelToStrip: 'Introduction'
      })
    ).toBe('Introduction of the new rules took a year.')
    // The heading and the first words of the body on one line are not a
    // heading line either.
    expect(
      shapePageText('Chapter One It began.', {
        tocLabelToStrip: 'Chapter One'
      })
    ).toBe('Chapter One It began.')
  })

  it('strips a label of symbols only when the line is exactly it', () => {
    expect(
      shapePageText('***\nLater that day.', { tocLabelToStrip: '***' })
    ).toBe('Later that day.')
    expect(
      shapePageText('*** Later that day.', { tocLabelToStrip: '***' })
    ).toBe('*** Later that day.')
  })

  it('leaves a blank page blank', () => {
    expect(shapePageText('')).toBe('')
    expect(shapePageText('  \n ', { tocLabelToStrip: 'Chapter One' })).toBe('')
  })
})

describe('createTocLabelResolver', () => {
  it('applies a label only to the first screen of the page it starts on', () => {
    const labelFor = createTocLabelResolver(metadata)

    expect(labelFor({ index: 0, page: 1 })).toBeUndefined()
    expect(labelFor({ index: 1, page: 2 })).toBe('Chapter One')
    expect(labelFor({ index: 2, page: 2 })).toBeUndefined()
    // A chunk from no page of this capture gets nothing stripped.
    expect(labelFor({ index: 9, page: 2 })).toBeUndefined()
  })
})

describe('withCurrentText', () => {
  it('rebuilds text from kept lines under the current rules', () => {
    const chunk: ContentChunk = {
      index: 0,
      page: 1,
      // What an older reconstruction stored: every line its own paragraph.
      text: 'The first line of a paragraph that\nwraps onto a second line.',
      screenshot: 'pages/000.png',
      lines: oneParagraphLines()
    }

    expect(withCurrentText([chunk], metadata)[0]!.text).toBe(
      'The first line of a paragraph that wraps onto a second line.'
    )
    // The stored record of the OCR run is not touched.
    expect(chunk.text).toContain('\n')
  })

  it('strips the TOC label from rebuilt text as the transcriber does', () => {
    const chunk: ContentChunk = {
      index: 1,
      page: 2,
      text: 'stale',
      screenshot: 'pages/001.png',
      lines: [
        { text: 'Chapter One', left: 300, top: 100, width: 300, height: 30 },
        ...oneParagraphLines().map((line) => ({ ...line, top: line.top + 200 }))
      ]
    }

    expect(withCurrentText([chunk], metadata)[0]!.text).toBe(
      'The first line of a paragraph that wraps onto a second line.'
    )
  })

  it('keeps the stored text of chunks with no lines to rebuild from', () => {
    const read: ContentChunk = {
      index: 0,
      page: 1,
      text: 'Read by a model.',
      screenshot: 'pages/000.png'
    }
    const blank: ContentChunk = {
      index: 2,
      page: 2,
      text: '',
      screenshot: 'pages/002.png',
      lines: []
    }

    const [readOut, blankOut] = withCurrentText([read, blank], metadata)
    expect(readOut).toBe(read)
    expect(blankOut).toBe(blank)
  })
})
