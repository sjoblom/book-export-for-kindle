import { describe, expect, test } from 'vitest'

import { normalizeAuthors } from './utils'

describe('normalizeAuthors', () => {
  test("turns Amazon's colon-delimited 'Last, First' string into names", () => {
    expect(normalizeAuthors(['Doe, Jane:Roe, John:'])).toEqual([
      'Jane Doe',
      'John Roe'
    ])
  })

  test('keeps every entry when authors arrive as separate strings', () => {
    expect(normalizeAuthors(['Doe, Jane', 'Roe, John'])).toEqual([
      'Jane Doe',
      'John Roe'
    ])
  })

  test('is a no-op on names that are already normalized', () => {
    const once = normalizeAuthors(['Doe, Jane:Roe, John:'])
    expect(normalizeAuthors(once)).toEqual(once)
  })

  test('drops duplicates and empty input', () => {
    expect(normalizeAuthors(['Doe, Jane:Doe, Jane:'])).toEqual(['Jane Doe'])
    expect(normalizeAuthors([])).toEqual([])
  })
})
