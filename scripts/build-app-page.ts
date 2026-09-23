/**
 * Writes dist-core/app.html: the web app's page rendered for the native Mac
 * app, which loads it from its Resources folder and talks to it over the
 * WebKit bridge instead of HTTP (macos/PLAN.md). Rendered at build time so the
 * app needs no Node — the page is plain HTML by the time it ships.
 *
 * Runs after `build:core`, whose tsup config cleans dist-core.
 */
import fs from 'node:fs/promises'
import path from 'node:path'

import { renderPage } from '../src/serve-page'

const outFile = path.resolve(import.meta.dirname, '..', 'dist-core', 'app.html')
await fs.mkdir(path.dirname(outFile), { recursive: true })
await fs.writeFile(outFile, renderPage({ transport: 'bridge' }))
console.log(`wrote ${path.relative(process.cwd(), outFile)}`)
