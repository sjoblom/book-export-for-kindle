import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'

import { isPositiveInteger } from './utils'

/**
 * Stored settings, so the CLI works from any directory.
 *
 * `dotenv` reads `.env` relative to the working directory, which is fine while
 * you're sitting in the repo and useless once the command is on your PATH.
 * This file lives in the home directory instead and is found from anywhere.
 *
 * Deliberately no Amazon password: signing in happens in the browser, and a
 * field for it here would only invite people to store one.
 */

export interface UserConfig {
  openaiApiKey?: string
  model?: string
  outDir?: string
  concurrency?: number
}

export function configDir(): string {
  return path.join(os.homedir(), '.kindle-export')
}

export function configPath(): string {
  return path.join(configDir(), 'config.json')
}

export async function loadConfig(): Promise<UserConfig> {
  try {
    const raw = await fs.readFile(configPath(), 'utf8')
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object') return {}

    const config = parsed as UserConfig
    // The file is hand-editable, and a bad concurrency only blows up in p-map
    // once transcription starts — after the capture, which can take an hour.
    // Dropping it falls back to the default instead of failing that late.
    if (
      config.concurrency !== undefined &&
      !isPositiveInteger(config.concurrency)
    ) {
      delete config.concurrency
    }

    return config
  } catch {
    // No config yet, or it's unreadable — defaults and flags still work.
    return {}
  }
}

export async function saveConfig(config: UserConfig): Promise<string> {
  await fs.mkdir(configDir(), { recursive: true, mode: 0o700 })

  const target = configPath()
  // It holds an API key, so keep it readable only by its owner.
  await fs.writeFile(target, `${JSON.stringify(config, null, 2)}\n`, {
    mode: 0o600
  })
  await fs.chmod(target, 0o600).catch(() => {})

  return target
}
