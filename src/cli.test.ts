import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type * as ConfigModule from './config'
import type { UserConfig } from './config'

type ActualConfig = typeof ConfigModule

// Reading the real ~/.kindle-export/config.json would make these tests depend
// on the machine they run on, and applyConfig copies a stored key into the
// environment.
let stored: UserConfig = {}
let saved: UserConfig | undefined
vi.mock('./config', () => ({
  loadConfig: async () => stored,
  saveConfig: async (config: UserConfig) => {
    saved = config
    return '/dev/null'
  }
}))

// `setup` asks its questions through these; each test scripts the answers and
// records which questions were asked at all.
const prompts = vi.hoisted(() => ({
  asked: [] as string[],
  localOcr: true
}))
vi.mock('@inquirer/prompts', () => ({
  password: async ({ message }: { message: string }) => {
    prompts.asked.push(`password: ${message}`)
    return 'sk-typed'
  },
  input: async ({ message, default: fallback }: any) => {
    prompts.asked.push(`input: ${message}`)
    return fallback ?? ''
  },
  confirm: async ({ message }: { message: string }) => {
    prompts.asked.push(`confirm: ${message}`)
    return false
  },
  checkbox: async () => []
}))
vi.mock('./vision-ocr', () => ({
  isVisionOcrAvailable: async () => prompts.localOcr
}))

const { applyConfig, parseArgs, setup } = await import('./cli')

const EMPTY: Parameters<typeof applyConfig>[0] = {
  command: 'all',
  asins: [],
  outDir: '',
  profileDir: '',
  json: false,
  formats: ['md'],
  keepPages: false,
  forceCapture: false,
  forceOcr: false,
  forceExport: false
}

beforeEach(() => {
  stored = {}
  saved = undefined
  prompts.asked = []
  prompts.localOcr = true
  vi.spyOn(console, 'log').mockImplementation(() => {})
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
})

describe('parseArgs', () => {
  it('treats a bare ASIN as the full pipeline', () => {
    const options = parseArgs(['B01H4G2J1U'])

    expect(options).toMatchObject({ command: 'all', asins: ['B01H4G2J1U'] })
  })

  it('recognises a leading command keyword', () => {
    expect(parseArgs(['capture', 'B01H4G2J1U'])).toMatchObject({
      command: 'capture',
      asins: ['B01H4G2J1U']
    })
  })

  it('normalises ASIN case and surrounding space', () => {
    expect(parseArgs([' b01h4g2j1u '])?.asins).toEqual(['B01H4G2J1U'])
  })

  it('rejects an ASIN that could escape the output directory', () => {
    // `clean ..` would otherwise resolve outside the book folder and delete a
    // directory that has nothing to do with the export.
    expect(() => parseArgs(['clean', '..'])).toThrow(/invalid ASIN/)
    expect(() => parseArgs(['clean', 'a/b'])).toThrow(/invalid ASIN/)
  })

  it('rejects an unknown option rather than reading it as an ASIN', () => {
    expect(() => parseArgs(['--nope'])).toThrow(/unknown option/)
  })

  it('rejects an unknown format', () => {
    expect(() => parseArgs(['--format', 'epub'])).toThrow(/unknown format/)
    expect(parseArgs(['--format', 'md,pdf'])?.formats).toEqual(['md', 'pdf'])
  })

  it('returns nothing for --help and --version', () => {
    expect(parseArgs(['--help'])).toBeUndefined()
    expect(parseArgs(['--version'])).toBeUndefined()
  })

  it('rejects a --concurrency or --limit that is not a positive integer', () => {
    // Caught at parse time: p-map would only reject it once transcription
    // starts, after a capture that can take an hour.
    for (const bad of ['x', '0', '-2', '1.5', '8x', ' ']) {
      expect(() => parseArgs(['--concurrency', bad, 'B01H4G2J1U'])).toThrow(
        /--concurrency requires a positive whole number/
      )
      expect(() => parseArgs(['list', '--limit', bad])).toThrow(
        /--limit requires a positive whole number/
      )
    }

    expect(parseArgs(['--concurrency', '4'])?.concurrency).toBe(4)
    expect(parseArgs(['list', '--limit', '10'])?.limit).toBe(10)
  })

  it('still accepts --force-export, as a no-op', () => {
    // Export always rewrites; the flag stays so existing scripts keep working.
    expect(parseArgs(['--force-export', 'B01H4G2J1U'])).toMatchObject({
      asins: ['B01H4G2J1U'],
      forceExport: false
    })
  })

  it('makes --force imply every stage', () => {
    expect(parseArgs(['--force', 'B01H4G2J1U'])).toMatchObject({
      forceCapture: true,
      forceOcr: true,
      forceExport: true
    })
  })

  it('leaves paths unset so applyConfig can resolve them', () => {
    // The contract between the two: parseArgs reports only what was actually
    // typed, and every fallback lives in applyConfig.
    const options = parseArgs(['B01H4G2J1U'])

    expect(options!.outDir).toBeUndefined()
    expect(options!.profileDir).toBeUndefined()
  })
})

describe('applyConfig', () => {
  it('fills in a blank profile directory', async () => {
    // Regression: `setup` builds its options by hand with empty strings, and
    // `??` only replaces null/undefined — so the blank survived every fallback
    // and reached mkdir(''), crashing the sign-in it had just offered.
    const options = await applyConfig({ ...EMPTY, command: 'login' })

    expect(options.profileDir).toBe(
      path.join(os.homedir(), '.kindle-export', 'profile')
    )
    expect(options.outDir).toBe('out')
  })

  it('prefers the environment over stored config', async () => {
    stored = { outDir: 'from-config' }
    vi.stubEnv('KINDLE_OUT_DIR', 'from-env')

    expect((await applyConfig({ ...EMPTY })).outDir).toBe('from-env')
  })

  it('falls back to stored config when the environment is silent', async () => {
    stored = { outDir: 'from-config' }

    expect((await applyConfig({ ...EMPTY })).outDir).toBe('from-config')
  })

  it('keeps a path that was given explicitly', async () => {
    stored = { outDir: 'from-config' }
    vi.stubEnv('KINDLE_OUT_DIR', 'from-env')

    const options = await applyConfig({
      ...EMPTY,
      outDir: 'from-flag',
      profileDir: '/tmp/profile'
    })

    expect(options.outDir).toBe('from-flag')
    expect(options.profileDir).toBe('/tmp/profile')
  })

  it('never takes the OCR model from stored config', async () => {
    // Older setups prefilled gpt-4.1-mini, which would silently send every
    // page to a paid API on a Mac that reads them for free.
    stored = { model: 'gpt-4.1-mini' } as UserConfig
    vi.stubEnv('OCR_MODEL', undefined)

    expect((await applyConfig({ ...EMPTY })).model).toBeUndefined()
  })

  it('takes the OCR model from OCR_MODEL or --model', async () => {
    vi.stubEnv('OCR_MODEL', 'gpt-from-env')
    expect((await applyConfig({ ...EMPTY })).model).toBe('gpt-from-env')

    const options = await applyConfig({ ...EMPTY, model: 'gpt-from-flag' })
    expect(options.model).toBe('gpt-from-flag')
    expect(parseArgs(['--model', 'gpt-5-mini'])?.model).toBe('gpt-5-mini')
  })

  it('treats an empty OCR_MODEL as not set', async () => {
    // A blank `OCR_MODEL=` line in .env must mean local OCR, not a model
    // called "" — and must not hide a real flag either.
    vi.stubEnv('OCR_MODEL', '')
    expect((await applyConfig({ ...EMPTY })).model).toBeUndefined()

    vi.stubEnv('OCR_MODEL', '  ')
    expect((await applyConfig({ ...EMPTY })).model).toBeUndefined()

    vi.stubEnv('OCR_MODEL', '')
    const options = await applyConfig({ ...EMPTY, model: 'gpt-from-flag' })
    expect(options.model).toBe('gpt-from-flag')
  })

  it('refuses an empty --model', () => {
    expect(() => parseArgs(['--model', ''])).toThrow(/requires a value/)
  })
})

describe('setup', () => {
  it('asks only for the output folder and sign-in when this Mac reads pages', async () => {
    prompts.localOcr = true

    await setup()

    expect(prompts.asked).toEqual([
      'input: Where should books be written?',
      'confirm: Sign in to Amazon now?'
    ])
    expect(saved).toEqual({ outDir: 'out' })
  })

  it('asks for an API key, but no model, without local OCR', async () => {
    prompts.localOcr = false

    await setup()

    expect(prompts.asked).toEqual([
      'password: OpenAI API key:',
      'input: Where should books be written?',
      'confirm: Sign in to Amazon now?'
    ])
    expect(saved).toEqual({ openaiApiKey: 'sk-typed', outDir: 'out' })
  })

  it('keeps a stored key and never writes a model', async () => {
    // loadConfig already strips a legacy model; this pins down that setup
    // itself adds none, whichever branch it takes.
    stored = { openaiApiKey: 'sk-old', outDir: 'books' }

    await setup()

    expect(saved).toEqual({ openaiApiKey: 'sk-old', outDir: 'books' })
    expect(saved).not.toHaveProperty('model')
  })
})

const actualConfig = await vi.importActual<ActualConfig>('./config')

/** Write a config file under the faked home directory, then read it back. */
async function loadStored(config: unknown): Promise<UserConfig> {
  await fs.mkdir(actualConfig.configDir(), { recursive: true })
  await fs.writeFile(actualConfig.configPath(), JSON.stringify(config))
  return actualConfig.loadConfig()
}

describe('loadConfig', () => {
  let home: string

  beforeEach(async () => {
    home = await fs.mkdtemp(path.join(os.tmpdir(), 'kindle-export-config-'))
    vi.spyOn(os, 'homedir').mockReturnValue(home)
  })

  afterEach(async () => {
    await fs.rm(home, { recursive: true, force: true })
  })

  it('drops a stored concurrency that p-map would reject', async () => {
    for (const concurrency of ['8', 0, -1, 2.5, null]) {
      expect(await loadStored({ concurrency, outDir: 'o' })).toEqual({
        outDir: 'o'
      })
    }
  })

  it('drops a model stored by an older setup', async () => {
    // Otherwise a save that spreads the loaded config would write it back.
    expect(await loadStored({ model: 'gpt-4.1-mini', outDir: 'o' })).toEqual({
      outDir: 'o'
    })
  })

  it('keeps a valid stored concurrency', async () => {
    expect(await loadStored({ concurrency: 4 })).toEqual({ concurrency: 4 })
  })
})
