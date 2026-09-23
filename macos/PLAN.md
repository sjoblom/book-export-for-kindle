# Native macOS app — plan and contracts

Goal: `Kindle Export.app` without Node and without Chrome, ~5–10 MB. The
terminal tool (`kindle-export`, Node + patchright) stays as it is and shares the
same pure logic and the same on-disk formats.

A spike (September 2026) proved the risky part: Kindle Cloud Reader runs in a
`WKWebView`; page images arrive through a `URL.createObjectURL` user-script
hook; `/renderer/render` TAR responses (toc.json, location_map.json,
metadata.json) arrive through a `fetch` hook; page turns work with synthesized
`NSEvent` key (ArrowRight, keyCode 124) and mouse events sent through
`window.sendEvent` — including while the window is minimized. Untrusted JS
`element.click()` on the reader chevrons does **not** work. Sign-in persists in
`WKWebsiteDataStore.default()`.

## Layout

```
src/core/               pure TypeScript, no Node APIs — shared by CLI and app
  index.ts              the KindleCore API below (bundle entry)
dist-core/kindle-core.js  IIFE bundle, defines globalThis.KindleCore (pnpm build:core)
macos/
  Package.swift         SwiftPM: KindleExportKit (library), KindleExport (app), tests
  Sources/KindleExportKit/
    Core/               JSCore.swift — runs kindle-core.js in JavaScriptCore
    Capture/            ReaderSession, CaptureEngine, Tar          (wave 1: capture)
    Pipeline/           BookStore, VisionOCR, Transcriber, Exporter,
                        PdfRenderer, LibraryService                (wave 1: pipeline)
    App/                AppModel (queue/state), Bridge             (wave 2)
  Sources/KindleExport/ main.swift, windows, menus                 (wave 2)
  Tests/KindleExportKitTests/
```

## On-disk formats — unchanged

The app writes exactly what the Node pipeline writes, so each side can finish
what the other started and outputs can be compared:
`<outDir>/<ASIN>/metadata.json` (BookMetadata, src/types.ts, key order as
`normalizeBookMetadata`), `pages/NNN-PPP.png` (1× CSS pixels, i.e. the 2×
blob downscaled by `deviceScaleFactor` 2), `content.json`
(`{captureId, chunks}` — ContentStore; chunks carry `lines` from Vision),
`<slug>.md`, `book.pdf`, and the `.lock/owner-<pid>-<token>.json` book lock
(src/book-lock.ts semantics: rename a staging dir onto `.lock`).

## KindleCore API (JavaScriptCore contract)

`globalThis.KindleCore` — every function takes and returns JSON-serializable
values (Swift passes JSON strings through `JSCore.call`). No Node globals, no
timers, no TextEncoder, no console required (JSC has none of them by default).

| function | signature | source today |
|---|---|---|
| `buildBookMetadata` | `({asin, renders: Array<{toc?: string, locationMap?: string, metadata?: string}>, yjMetadata?: object, startReading?: object}) → {meta, info, toc, locationMap, nav} ` — `renders` are the raw file texts from each `/renderer/render` TAR in arrival order; mirrors the network handlers + post-load nav computation in extractBook | extract-kindle-book.ts L420–566, L1117–1162 |
| `pageForPosition` | `(locationMap, position) → number` | getPageForPosition |
| `parsePageNav` | `(footerText: string \| null) → PageNav \| null` | playwright-utils.ts |
| `normalizePageNumber` | `(pageNav \| null, locationMap, fallbackPage) → number` | normalizePageNumberFromNav |
| `isOnLastNumberedPage`, `maxNavigationAttempts`, `chevronClickTimeoutMs`, `navigationTimeoutMs`, `shouldStopBeforeCapture`, `shouldStopCapture`, `shouldRecover`, `resumeScreenDecision`, `isStall` | as in capture-termination.ts | capture-termination.ts |
| `pageTextFromLines` | `(lines: OcrLine[], tocLabelToStrip?: string) → string` = shapePageText(reconstructParagraphs(lines)) | ocr-layout.ts, page-text.ts |
| `tocLabelsForChunks` | `(metadata, chunks: Array<{index, page}>) → Array<string \| null>` (the label to strip per chunk) | page-text.ts createTocLabelResolver |
| `selectReusableChunks` | `(store \| null, metadata) → ContentChunk[]` | content-store.ts |
| `bookCompleteness` | `({metadata?, content?, asin?}) → BookCompleteness` | capture-status.ts |
| `renderMarkdown` | `(metadata, chunks) → {fileName, markdown}` (applies withCurrentText + selectReusableChunks exactly like exportBookMarkdown) | export-book-markdown.ts |
| `pdfDocument` | `(metadata, chunks) → {title, authors: string[], sections: Array<{label, depth, text}>}` (text as export-book-pdf.ts formats it) | export-book-pdf.ts |
| `parseLibraryPage` | `(payload) → {books, paginationToken?}` | kindle-library.ts |
| `normalizeAuthors` | `(string[]) → string[]` | utils.ts |

`JSCore.call(name, args...)` encodes args as JSON, calls
`KindleCore[name](...JSON.parse(args))`, and decodes the JSON-stringified
result. Errors thrown in JS surface as Swift errors with the JS message.

## Behaviour to port (Swift) — reference the TS

- Capture: extract-kindle-book.ts `extractBook` — load reader, dismiss "Most
  Recent Page Read" (answer No), settings (Amazon Ember font, single column) by
  real mouse clicks, record initial page nav, go to start page via the Go to
  Page modal (type digits with key events) or walk, the capture loop with the
  termination and recovery decisions from KindleCore, metadata.json rewritten
  after every screen, restore the reading position at the end.
- Transcribe: transcribe-book-content.ts — Vision per page (VNRecognizeText
  accurate, language correction on), retries, blank pages, failed pages,
  content.json saved incrementally and atomically, page images removed once
  every page has text (pipeline.ts).
- Export: Markdown via `renderMarkdown`; PDF from `pdfDocument` rendered with
  a WKWebView print operation (paginated) or CoreText.
- App: serve.ts `App` (queue, states, library cache, auto sign-in once per
  launch) and serve-page.ts (the UI) talking over a WKScriptMessageHandler
  bridge instead of HTTP + SSE.

## Wave 2 — the app shell

### Page ↔ Swift bridge (replaces HTTP + SSE inside the app)

The page (src/serve-page.ts) keeps one API vocabulary — the routes and JSON
bodies of src/serve.ts — and gains a transport layer:

- `kindle-export serve` (browser): `fetch('/api/…')` + `EventSource('/api/events')`
  exactly as today.
- In the app (`window.webkit?.messageHandlers?.kindle` present, or the page
  was rendered with `transport: 'bridge'`):
  - request: `window.webkit.messageHandlers.kindle.postMessage({ id, method, path, body })`
    with the same `method`/`path`/`body` the HTTP call would use (e.g.
    `{method:'POST', path:'/api/export', body:{asin}}`).
  - reply: Swift calls `window.__kindleReply(id, status, json)` — `status` is
    the HTTP status the server would have sent, `json` the same body (errors as
    `{error}` with 4xx/5xx).
  - state pushes: Swift calls `window.__kindleState(json)` with the same object
    `/api/events` streams (the AppState of serve.ts), debounced ~150 ms.
  - downloads: the page sends `{method:'GET', path:'/api/download/<asin>/<name>'}`
    through the bridge instead of navigating; Swift saves the file to
    ~/Downloads (unique name) and reveals it in Finder; reply `{saved: path}`.
  - `POST /api/reveal` → Swift `NSWorkspace` reveal.
- `renderPage({ transport })` — the app bundles the page rendered with
  `transport: 'bridge'` as `app.html` (built by `pnpm build:app-page` into
  `dist-core/app.html`).

### Swift app responsibilities (port of src/serve.ts `App`)

AppModel (@MainActor): the same state shape and behaviour as serve.ts —
library from cache on launch, background refresh, one automatic sign-in per
launch (showing the reader window), queue with remove/stop-after-current,
per-book status from pipeline events, disk scan (BookStatus), alsoPdf setting
(stored in ~/.kindle-export/config.json like the CLI), API key state is moot
(no OpenAI in the app: `needsApiKey` always false, `localOcr` true).
Windows: ONE visible window. The main window hosts the UI page; the
ReaderSession's web view lives in an invisible `ReaderHostWindow` (borderless,
ordered in off-screen, excluded from the Windows menu, `.transient` +
`.ignoresCycle`, never key/main, never minimized) during capture and library
refresh. When Amazon wants a sign-in (auto sign-in at launch, the "Sign in to
Amazon" button, or mid-capture via CaptureEngine's signInHandler),
NativeBackend sets `placement = .signIn` and the app moves the *same* web view
into the main window under a native `SignInView` bar ("Sign in to Amazon to
see your books" + Cancel), faded in over the page (which stays loaded
underneath). A signed-in reader URL seen on two consecutive polls (not
loading) or Cancel sets `placement = .background` and the web view goes back
to the host at 1280×720. Synthesized events go to `webView.window`, whichever
window that is. Verified: a full capture (page turns, Go to Page, settings
clicks) runs in the off-screen host window — see "Off-screen hosting" below.
Developer autotest: `KINDLE_EXPORT_AUTOTEST=<ASIN> [KINDLE_EXPORT_OUT_DIR=<dir>]`
exports one book with no one at the keyboard and writes
`<outDir>/autotest-result.json`, then quits. Menus: Edit (copy/paste), View › Reload, Window, Show Books in
Finder. Quit while exporting asks first. Books go to ~/Documents/Kindle Export.

### Off-screen hosting (verified September 2026)

Measured with the autotest on "How to Live" (B09Y7P4DR6, 116 pages, 210
screens):

- Borderless window ordered in far outside every screen, nothing else: WebKit
  reports the page hidden (`visibilityState` "hidden", no
  `requestAnimationFrame`), the reader never lays out its toolbar ("Reader
  settings button not found"). AppKit's `occlusionState` still says visible;
  WebKit decides on its own.
- Same, at a level below the desktop with `.canJoinAllSpaces`: hidden too.
- **Off-screen + `WKWebView._setWindowOcclusionDetectionEnabled:NO`** (SPI,
  called through the runtime, present since macOS 10.13): page visible, rAF at
  60 fps, full capture complete — 210 screens, end-of-book, restore OK, ~2.5
  min. This is the default.
- **Sliver** (1 pt of the window on the main screen's corner, alpha 0.01,
  below the desktop level; public API only): also visible and a full capture
  completes identically. Used automatically when the SPI is missing;
  `KINDLE_EXPORT_HOST_MODE=sliver` forces it.
- Minimized (the old approach) was not needed.

Found along the way: WebKit's reader renders pages further ahead than
Chrome's — the blob for screen 10 arrived while screen 1 was consumed — so
BlobStore's age limit (8 consumptions, as extract-kindle-book.ts) aged it out
and failed every capture at screen 10. The default is now 32 (bounded by
`maxCount` 64).

