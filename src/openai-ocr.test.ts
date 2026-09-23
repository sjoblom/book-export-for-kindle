import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'

import { APIConnectionError, APIError } from 'openai-fetch'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

import {
  OcrPageUnreadableError,
  OcrRefusalError,
  OcrUnavailableError
} from './ocr-engine'
import { createOpenAiOcrEngine, isRefusal } from './openai-ocr'

function engineThrowing(err: unknown) {
  return createOpenAiOcrEngine({
    model: 'gpt-test',
    client: {
      async createChatCompletion() {
        throw err
      }
    }
  })
}

function apiError(status: number, code?: string): APIError {
  return new APIError(
    status,
    { message: `status ${status}`, ...(code ? { code } : {}) },
    undefined,
    {}
  )
}

describe('isRefusal', () => {
  it.each([
    "I'm sorry, I can't help with that.",
    "I'm sorry, but I can't assist with that request.",
    'I’m sorry, but I can’t provide verbatim text from this image.',
    "Sorry, I can't help with that.",
    'Sorry, but I cannot transcribe copyrighted material.',
    'I am sorry, but I am unable to transcribe this image.',
    "I can't assist with that.",
    'I cannot transcribe the text in this image.',
    "I'm unable to transcribe this page.",
    "I'm not able to help with that.",
    "I can't help you with that.",
    'I won’t transcribe this text.'
  ])('recognises the refusal %j', (text) => {
    expect(isRefusal(text)).toBe(true)
  })

  it.each([
    // Everyday prose the old pattern treated as a refusal.
    'He was unable to sleep.',
    'For details, see our privacy policy.',
    'The company policy was clear on this.',
    'She was unable to comply with his request.',
    // First person, but a narrator rather than an assistant.
    "I'm sorry, Tom. I didn't mean it.",
    "I can't help it, she said. I never could.",
    'I cannot help but wonder what became of him.',
    'I can’t provide for them any longer.',
    'I am unable to explain what happened next.',
    // Dialogue quoting a refusal, and a refusal that is not the opening.
    '"I can\'t help with that," he said, and turned away.',
    "He said: I'm sorry, but I can't help with that.",
    'Chapter 3\nI cannot transcribe my grief into words.',
    // A real refusal, but too long to be one reply: a page that says it.
    `I can't help with that. ${'The night went on and on. '.repeat(10)}`
  ])('reads %j as page text', (text) => {
    expect(isRefusal(text)).toBe(false)
  })
})

describe('createOpenAiOcrEngine', () => {
  let dir: string
  let imagePath: string

  beforeAll(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'kindle-export-ocr-'))
    imagePath = path.join(dir, 'page.png')
    await fs.writeFile(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]))
  })

  afterAll(async () => {
    await fs.rm(dir, { recursive: true, force: true })
  })

  function recognize(engine: ReturnType<typeof createOpenAiOcrEngine>) {
    return engine.recognize({
      imagePath,
      attempt: 0,
      signal: new AbortController().signal
    })
  }

  it('throws only a genuine refusal as a refusal', async () => {
    const engine = createOpenAiOcrEngine({
      client: {
        async createChatCompletion() {
          return {
            choices: [{ message: { content: "I'm sorry, I can't help." } }]
          }
        }
      }
    })
    // "help" alone, with no object, is not enough to call it a refusal.
    await expect(recognize(engine)).resolves.toEqual({
      text: "I'm sorry, I can't help."
    })

    const refusing = createOpenAiOcrEngine({
      client: {
        async createChatCompletion() {
          return {
            choices: [
              { message: { content: "I'm sorry, I can't assist with that." } }
            ]
          }
        }
      }
    })
    await expect(recognize(refusing)).rejects.toBeInstanceOf(OcrRefusalError)
  })

  it('throws a structured refusal as a refusal, not as an empty page', async () => {
    const engine = createOpenAiOcrEngine({
      client: {
        async createChatCompletion() {
          return {
            choices: [
              {
                message: {
                  content: null,
                  refusal: "I'm sorry, I can't help with that."
                },
                finish_reason: 'stop'
              }
            ]
          }
        }
      }
    })

    await expect(recognize(engine)).rejects.toBeInstanceOf(OcrRefusalError)
  })

  it('treats a reply stopped by the content filter as a refusal', async () => {
    const engine = createOpenAiOcrEngine({
      client: {
        async createChatCompletion() {
          return {
            // Whatever made it out before the filter is not the whole page.
            choices: [
              {
                message: { content: 'The first half of' },
                finish_reason: 'content_filter'
              }
            ]
          }
        }
      }
    })

    await expect(recognize(engine)).rejects.toBeInstanceOf(OcrRefusalError)
  })

  it('ignores an empty refusal field', async () => {
    const engine = createOpenAiOcrEngine({
      client: {
        async createChatCompletion() {
          return {
            choices: [
              {
                message: { content: 'Page text.', refusal: null },
                finish_reason: 'stop'
              }
            ]
          }
        }
      }
    })

    await expect(recognize(engine)).resolves.toEqual({ text: 'Page text.' })
  })

  it('reports a rejected key as the whole engine being unusable', async () => {
    const recognizing = recognize(engineThrowing(apiError(401)))
    await expect(recognizing).rejects.toBeInstanceOf(OcrUnavailableError)
    await expect(recognizing).rejects.toThrow('OpenAI rejected the API key')
  })

  it.each([403, 404])(
    'reports HTTP %i as the whole engine being unusable',
    async (status) => {
      await expect(
        recognize(engineThrowing(apiError(status)))
      ).rejects.toBeInstanceOf(OcrUnavailableError)
    }
  )

  it('names the model OpenAI does not know', async () => {
    await expect(recognize(engineThrowing(apiError(404)))).rejects.toThrow(
      /gpt-test/
    )
  })

  it('tells an empty account apart from a rate limit', async () => {
    await expect(
      recognize(engineThrowing(apiError(429, 'insufficient_quota')))
    ).rejects.toBeInstanceOf(OcrUnavailableError)

    const rateLimited = await recognize(engineThrowing(apiError(429))).catch(
      (err: unknown) => err
    )
    expect(rateLimited).toBeInstanceOf(APIError)
    expect(rateLimited).not.toBeInstanceOf(OcrUnavailableError)
  })

  it('reports a rejected request as this page being unreadable', async () => {
    await expect(
      recognize(engineThrowing(apiError(400)))
    ).rejects.toBeInstanceOf(OcrPageUnreadableError)
  })

  it.each([
    ['a server error', apiError(503)],
    ['a dropped connection', new APIConnectionError({})],
    ['anything else', new Error('socket hang up')]
  ])('leaves %s to be retried', async (_, thrown) => {
    const err = await recognize(engineThrowing(thrown)).catch(
      (err: unknown) => err
    )
    expect(err).toBe(thrown)
  })
})
