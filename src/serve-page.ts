/**
 * The web app's single page: markup, styles and client script in one string,
 * served with no external scripts, styles or fonts so it works offline. The
 * one thing fetched from elsewhere is each book's cover thumbnail, straight
 * from Amazon's image host (the server only passes on https URLs on Amazon's
 * own image domains, and the request carries no referrer); a book without one
 * gets a drawn placeholder instead.
 *
 * The client script deliberately avoids template literals — the whole page
 * lives inside one TypeScript template string, and nested backticks are a
 * silent way to break it. DOM nodes are built with a small helper instead,
 * which also means book titles are always set via textContent, never HTML.
 *
 * The same page runs inside the native Mac app, loaded from a file, where it
 * reaches the app through a WebKit message handler instead of HTTP — hence the
 * transport option below. Nothing in it may depend on a relative URL: under a
 * file:// origin those resolve to nothing.
 */
export type PageTransport = 'http' | 'bridge'

export interface RenderPageOptions {
  /**
   * How the page talks to its backend. `http` (the default) is
   * `kindle-export serve`: fetch + server-sent events against the local
   * server. `bridge` is the native Mac app, where the page is loaded from a
   * file and every call goes through a WKScriptMessageHandler instead — see
   * macos/PLAN.md, "Page ↔ Swift bridge". The API vocabulary (routes, bodies,
   * status codes) is the same either way; only the carrier differs.
   */
  transport?: PageTransport
}

export function renderPage(options: RenderPageOptions = {}): string {
  const transport =
    options.transport === 'bridge' ? BRIDGE_TRANSPORT : HTTP_TRANSPORT
  // split/join rather than replace(): replace() would interpret `$` patterns
  // in the inserted script.
  return PAGE.split('/*TRANSPORT*/').join(transport)
}

/*
 * The transport layer. Each variant defines the same five functions, and the
 * rest of the page only ever calls these:
 *   request(method, path, body) → Promise of the JSON reply; rejects with an
 *     Error whose message is fit for a toast
 *   api(path, body)             → a POST through request()
 *   reload(scan)                → fetch the whole state once and render it
 *   listenForState()            → start receiving state pushes
 *   downloadControl(attrs, asin, name) → the element for a Download action
 * Only the selected variant is emitted, so the app's page carries no fetch or
 * EventSource at all and the browser page no bridge hooks.
 */

const HTTP_TRANSPORT = `// Where Amazon runs: kindle-export serve drives a separate Chrome window,
// which the person signs in in while this page waits.
var READER = {
  signingInStatus: 'Waiting for you to sign in to Amazon…',
  signingIn: {
    title: 'Sign in to Amazon in the Chrome window',
    text: 'A Chrome window has opened on Amazon’s sign-in page. Sign in the way you always do — including any code Amazon sends you. The window closes by itself when you’re done. This app never sees your password.'
  },
  signIn: 'A Chrome window opens on Amazon’s own sign-in page. Your password is never seen or stored by this app.',
  reading: 'Chrome is reading the book in a minimized window — no need to touch it. It closes on its own; if Amazon wants you to sign in, it pops up by itself.'
}

function request(method, path, body) {
  var init = { method: method }
  if (method !== 'GET') {
    // Every write carries the app header: the server refuses writes without
    // it, which a cross-site form post cannot add.
    init.headers = { 'content-type': 'application/json', 'x-kindle-export': '1' }
    init.body = JSON.stringify(body || {})
  }
  return fetch(path, init).then(function (res) {
    return res.json().catch(function () { return {} }).then(function (data) {
      if (!res.ok) throw new Error(data.error || ('Something went wrong (' + res.status + ').'))
      return data
    })
  }, function () {
    throw new Error('Kindle Export is not responding. Is it still running?')
  })
}

function api(path, body) {
  return request('POST', path, body)
}

function reload(scan) {
  return request('GET', '/api/state' + (scan ? '?scan=1' : '')).then(function (data) {
    state = data
    render()
  }).catch(function (err) {
    toast(err.message)
  })
}

function listenForState() {
  var events = new EventSource('/api/events')
  events.onmessage = function (event) {
    state = JSON.parse(event.data)
    render()
  }
}

function downloadControl(attrs, asin, name) {
  attrs.href = downloadPath(asin, name)
  attrs.download = name
  return el('a', attrs)
}`

const BRIDGE_TRANSPORT = `// Where Amazon runs: inside the app, out of sight — there is no Chrome and
// no second window. For sign-in the app shows Amazon's page in place of this
// one, so there is nothing to point at here while it is up.
var READER = {
  signingInStatus: 'Signing in to Amazon…',
  signingIn: null,
  signIn: 'Opens Amazon’s sign-in page in this window.',
  reading: 'Reading the book — this takes a while; you can keep using your Mac.'
}

// A reply that never comes (the app busy, or a bug on the Swift side) must
// not leave a button disabled forever; after this long the call fails with a
// toast and a late reply is dropped.
var BRIDGE_TIMEOUT_MS = 30000
var pending = {}
var nextRequestId = 1

// Swift evaluates these with the JSON either inlined as a literal or as a
// string; accept both rather than depend on which one it picked.
function parseBridgeJson(json) {
  if (typeof json !== 'string') return json || {}
  try { return JSON.parse(json) } catch (err) { return {} }
}

function request(method, path, body) {
  return new Promise(function (resolve, reject) {
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kindle
    if (!handler) {
      reject(new Error('This page only works inside the Kindle Export app.'))
      return
    }
    var id = String(nextRequestId++)
    var timer = setTimeout(function () {
      delete pending[id]
      reject(new Error('Kindle Export did not answer. Please try again.'))
    }, BRIDGE_TIMEOUT_MS)
    pending[id] = { resolve: resolve, reject: reject, timer: timer }
    var message = { id: id, method: method, path: path }
    if (method !== 'GET') message.body = body || {}
    try {
      handler.postMessage(message)
    } catch (err) {
      clearTimeout(timer)
      delete pending[id]
      reject(new Error('Kindle Export did not answer. Please try again.'))
    }
  })
}

window.__kindleReply = function (id, status, json) {
  var entry = pending[String(id)]
  if (!entry) return
  delete pending[String(id)]
  clearTimeout(entry.timer)
  var data = parseBridgeJson(json)
  if (status >= 200 && status < 300) entry.resolve(data)
  else entry.reject(new Error(data.error || ('Something went wrong (' + status + ').')))
}

function api(path, body) {
  return request('POST', path, body)
}

function reload(scan) {
  return request('GET', '/api/state' + (scan ? '?scan=1' : '')).then(function (data) {
    state = data
    render()
  }).catch(function (err) {
    toast(err.message)
  })
}

// The same object /api/events streams, pushed by the app whenever it changes.
function listenForState() {
  window.__kindleState = function (json) {
    state = parseBridgeJson(json)
    render()
  }
}

// A link would navigate the app's web view to a URL nothing serves; instead
// the app saves the file to Downloads and shows it in Finder.
function downloadControl(attrs, asin, name) {
  attrs.type = 'button'
  var node = el('button', attrs)
  node.addEventListener('click', function () {
    node.disabled = true
    request('GET', downloadPath(asin, name)).then(function () {
      toast('Saved “' + name + '” to Downloads.', 'good')
    }, function (err) {
      toast(err.message)
    }).then(function () {
      node.disabled = false
    })
  })
  return node
}`

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Kindle Export</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📖</text></svg>">
<style>
:root {
  color-scheme: light dark;
  --bg: #f5f5f7;
  --surface: #ffffff;
  --surface-2: #fbfbfd;
  --text: #1d1d1f;
  --muted: #6e6e73;
  --faint: #8e8e93;
  --border: rgba(0, 0, 0, 0.1);
  --border-strong: rgba(0, 0, 0, 0.18);
  --accent: #0071e3;
  --accent-hover: #0077ed;
  --accent-text: #ffffff;
  --accent-soft: rgba(0, 113, 227, 0.1);
  --good: #1f8a3b;
  --good-soft: rgba(52, 199, 89, 0.14);
  --warn: #a15c00;
  --warn-soft: rgba(255, 159, 10, 0.16);
  --bad: #c9162b;
  --bad-soft: rgba(255, 59, 48, 0.12);
  --track: rgba(0, 0, 0, 0.08);
  --shadow: 0 1px 2px rgba(0, 0, 0, 0.06), 0 4px 14px rgba(0, 0, 0, 0.06);
  --shadow-lift: 0 2px 6px rgba(0, 0, 0, 0.08), 0 12px 28px rgba(0, 0, 0, 0.12);
  --topbar: rgba(245, 245, 247, 0.82);
  --skeleton: rgba(0, 0, 0, 0.06);
  --focus: 0 0 0 3px rgba(0, 113, 227, 0.45);
  --radius: 12px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #1c1c1e;
    --surface: #2c2c2e;
    --surface-2: #242426;
    --text: #f5f5f7;
    --muted: #a1a1a6;
    --faint: #8e8e93;
    --border: rgba(255, 255, 255, 0.1);
    --border-strong: rgba(255, 255, 255, 0.2);
    --accent: #0a84ff;
    --accent-hover: #409cff;
    --accent-text: #ffffff;
    --accent-soft: rgba(10, 132, 255, 0.18);
    --good: #32d74b;
    --good-soft: rgba(50, 215, 75, 0.16);
    --warn: #ffb340;
    --warn-soft: rgba(255, 159, 10, 0.18);
    --bad: #ff6961;
    --bad-soft: rgba(255, 69, 58, 0.18);
    --track: rgba(255, 255, 255, 0.14);
    --shadow: 0 1px 2px rgba(0, 0, 0, 0.3), 0 4px 14px rgba(0, 0, 0, 0.25);
    --shadow-lift: 0 2px 6px rgba(0, 0, 0, 0.35), 0 12px 28px rgba(0, 0, 0, 0.4);
    --topbar: rgba(28, 28, 30, 0.82);
    --skeleton: rgba(255, 255, 255, 0.07);
    --focus: 0 0 0 3px rgba(10, 132, 255, 0.55);
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; }
body {
  background: var(--bg);
  color: var(--text);
  font: 14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
  min-height: 100vh;
}
[hidden] { display: none !important; }
.sr-only {
  position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0;
}
svg.icon { width: 16px; height: 16px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }

/* ---------------------------------------------------------------- top bar */
.topbar {
  position: sticky;
  top: 0;
  z-index: 20;
  background: var(--topbar);
  -webkit-backdrop-filter: saturate(180%) blur(20px);
  backdrop-filter: saturate(180%) blur(20px);
  border-bottom: 1px solid var(--border);
}
.topbar-inner {
  max-width: 1280px;
  margin: 0 auto;
  padding: 10px 20px;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px 14px;
}
.brand { display: flex; align-items: center; gap: 10px; min-width: 0; flex: 1 1 auto; }
.brand-mark {
  width: 28px; height: 28px; flex: none;
  border-radius: 7px;
  background: linear-gradient(160deg, #3a8dff, #0058c7);
  color: #fff;
  display: grid; place-items: center;
}
.brand-mark svg.icon { width: 17px; height: 17px; }
.brand-text { min-width: 0; }
.brand-name { font-weight: 600; font-size: 15px; letter-spacing: -0.01em; white-space: nowrap; }
.status { color: var(--muted); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; gap: 6px; }
.dot { width: 7px; height: 7px; border-radius: 50%; background: var(--faint); flex: none; }
.dot.good { background: var(--good); }
.dot.warn { background: var(--warn); }
.dot.busy { background: var(--accent); animation: pulse 1.4s ease-in-out infinite; }
@keyframes pulse { 50% { opacity: 0.35; } }
.tools { display: flex; align-items: center; gap: 6px; flex: 1 1 320px; max-width: 460px; margin-left: auto; }
.search { position: relative; flex: 1; min-width: 0; }
.search svg.icon { position: absolute; left: 10px; top: 50%; transform: translateY(-50%); color: var(--faint); pointer-events: none; }
.search input {
  width: 100%;
  height: 32px;
  padding: 0 10px 0 32px;
  border-radius: 8px;
  border: 1px solid var(--border);
  background: var(--surface);
  color: var(--text);
  font: inherit;
  -webkit-appearance: none;
  appearance: none;
}
.search input::placeholder { color: var(--faint); }
.search input:focus { outline: none; box-shadow: var(--focus); border-color: var(--accent); }
.icon-btn {
  width: 32px; height: 32px; flex: none;
  display: grid; place-items: center;
  border-radius: 8px;
  border: 1px solid transparent;
  background: transparent;
  color: var(--muted);
  cursor: pointer;
  padding: 0;
}
.icon-btn:hover:not(:disabled) { background: var(--track); color: var(--text); }
.icon-btn[aria-expanded="true"] { background: var(--track); color: var(--text); }
.icon-btn:disabled { opacity: 0.4; cursor: default; }
.icon-btn.spinning svg.icon { animation: spin 1s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
@media (max-width: 700px) {
  .tools { flex-basis: 100%; max-width: none; order: 3; }
}

/* ------------------------------------------------------------------- menu */
.menu-wrap { position: relative; }
.menu {
  position: absolute;
  right: 0;
  top: 40px;
  width: min(340px, calc(100vw - 32px));
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  box-shadow: var(--shadow-lift);
  padding: 6px;
  z-index: 30;
}
.menu-section { padding: 10px 12px; }
.menu-section + .menu-section { border-top: 1px solid var(--border); }
.menu-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--faint); margin: 0 0 6px; }
.menu-path { font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); word-break: break-all; margin: 0 0 8px; user-select: text; }
.menu-item {
  display: flex; align-items: center; gap: 8px;
  width: 100%;
  padding: 7px 10px;
  margin: 0 -10px;
  width: calc(100% + 20px);
  border: 0; border-radius: 7px;
  background: transparent; color: var(--text);
  font: inherit; text-align: left; cursor: pointer;
}
.menu-item:hover:not(:disabled) { background: var(--accent-soft); }
.menu-item:disabled { opacity: 0.5; cursor: default; }
.switch-row { display: flex; align-items: flex-start; gap: 10px; cursor: pointer; }
.switch-row .switch-text { flex: 1; }
.switch-row small { display: block; color: var(--muted); font-size: 12px; margin-top: 2px; }
.switch {
  -webkit-appearance: none; appearance: none;
  width: 34px; height: 20px; flex: none; margin: 1px 0 0;
  border-radius: 999px; background: var(--track);
  position: relative; cursor: pointer; transition: background 0.2s;
}
.switch::after {
  content: ""; position: absolute; top: 2px; left: 2px;
  width: 16px; height: 16px; border-radius: 50%;
  background: #fff; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
  transition: transform 0.2s;
}
.switch:checked { background: var(--good); }
.switch:checked::after { transform: translateX(14px); }
.switch:focus-visible { outline: none; box-shadow: var(--focus); }
.log {
  margin-top: 8px;
  font: 11px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px 10px;
  max-height: 200px;
  overflow-y: auto;
  white-space: pre-wrap;
  word-break: break-word;
  color: var(--muted);
}
.log .warn { color: var(--warn); }
details summary { cursor: pointer; color: var(--muted); font-size: 13px; }

/* ----------------------------------------------------------------- layout */
main { max-width: 1280px; margin: 0 auto; padding: 16px 20px 64px; }
@media (max-width: 600px) {
  .topbar-inner { padding: 10px 16px; }
  main { padding: 14px 16px 56px; }
}

/* ---------------------------------------------------------------- buttons */
.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  height: 30px; padding: 0 12px;
  border-radius: 8px;
  border: 1px solid var(--border-strong);
  background: var(--surface);
  color: var(--text);
  font: inherit; font-size: 13px; font-weight: 500;
  text-decoration: none; white-space: nowrap;
  cursor: pointer;
}
.btn:hover:not(:disabled) { background: var(--surface-2); border-color: var(--faint); }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
.btn.primary:hover:not(:disabled) { background: var(--accent-hover); border-color: var(--accent-hover); }
.btn.tint { background: var(--accent-soft); border-color: transparent; color: var(--accent); font-weight: 600; }
.btn.tint:hover:not(:disabled) { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
.btn.quiet { border-color: transparent; background: transparent; color: var(--muted); }
.btn.quiet:hover:not(:disabled) { background: var(--track); color: var(--text); border-color: transparent; }
.btn:disabled { opacity: 0.5; cursor: default; }
.btn.icon-only { width: 30px; padding: 0; }
button:focus-visible, a:focus-visible, input:focus-visible, summary:focus-visible {
  outline: none;
  box-shadow: var(--focus);
}

/* ---------------------------------------------------------------- notices */
.notices { display: flex; flex-direction: column; gap: 10px; margin-bottom: 16px; }
.notices:empty { display: none; }
.notice {
  display: flex; align-items: center; gap: 12px; flex-wrap: wrap;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  padding: 12px 14px;
}
.notice-icon {
  width: 30px; height: 30px; flex: none; border-radius: 50%;
  display: grid; place-items: center;
  background: var(--accent-soft); color: var(--accent);
}
.notice.warn .notice-icon { background: var(--warn-soft); color: var(--warn); }
.notice.bad .notice-icon { background: var(--bad-soft); color: var(--bad); }
.notice-body { flex: 1 1 240px; min-width: 0; }
.notice-title {
  font-weight: 600;
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
}
.notice-text { color: var(--muted); font-size: 13px; }
.notice-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.key-form { display: flex; gap: 8px; }
.key-form input {
  flex: 1; min-width: 0; height: 30px; padding: 0 10px;
  border-radius: 8px; border: 1px solid var(--border-strong);
  background: var(--surface-2); color: var(--text); font: inherit;
}
.notice form { display: flex; gap: 8px; flex: 1 1 100%; flex-wrap: wrap; }
.notice input[type=password] {
  flex: 1 1 220px; height: 30px; padding: 0 10px;
  border-radius: 8px; border: 1px solid var(--border-strong);
  background: var(--surface-2); color: var(--text); font: inherit;
}
.notice .bar { flex: 1 1 100%; }

/* ---------------------------------------------------------------- filters */
.filterbar { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; flex-wrap: wrap; }
.segmented { display: inline-flex; background: var(--track); border-radius: 8px; padding: 2px; }
.segmented button {
  border: 0; background: transparent; color: var(--muted);
  font: inherit; font-size: 12.5px; font-weight: 500;
  padding: 4px 12px; border-radius: 6px; cursor: pointer;
}
.segmented button[aria-pressed="true"] { background: var(--surface); color: var(--text); box-shadow: 0 1px 2px rgba(0, 0, 0, 0.12); }
.filtercount { color: var(--faint); font-size: 12.5px; }

/* ------------------------------------------------------------------- grid */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 26px 18px;
}
@media (min-width: 1000px) { .grid { grid-template-columns: repeat(auto-fill, minmax(168px, 1fr)); } }
.card { display: flex; flex-direction: column; min-width: 0; }
.cover {
  position: relative;
  aspect-ratio: 2 / 3;
  border-radius: 8px;
  overflow: hidden;
  background: var(--skeleton);
  box-shadow: var(--shadow);
  transition: box-shadow 0.2s, transform 0.2s;
}
.card:hover .cover { box-shadow: var(--shadow-lift); }
.cover img {
  position: absolute; inset: 0; width: 100%; height: 100%;
  object-fit: cover; display: block;
}
.placeholder {
  position: absolute; inset: 0;
  display: flex; flex-direction: column; justify-content: space-between;
  padding: 14px 12px;
  color: rgba(255, 255, 255, 0.95);
  background: linear-gradient(155deg, hsl(var(--hue), 42%, 46%), hsl(calc(var(--hue) + 28), 48%, 30%));
}
.placeholder .initials { font-size: 34px; font-weight: 700; letter-spacing: -0.02em; line-height: 1; opacity: 0.9; }
.placeholder .ph-title {
  font-size: 12.5px; font-weight: 600; line-height: 1.3;
  display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden;
}
.cover-action {
  position: absolute; inset: 0;
  border: 0; padding: 0; margin: 0;
  background: transparent;
  cursor: pointer;
  display: flex; align-items: flex-end; justify-content: center;
  padding-bottom: 14px;
}
.cover-action span {
  display: inline-flex; align-items: center; gap: 6px;
  background: rgba(0, 0, 0, 0.72); color: #fff;
  -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px);
  padding: 6px 12px; border-radius: 999px;
  font-size: 12.5px; font-weight: 600;
  opacity: 0; transform: translateY(4px);
  transition: opacity 0.15s, transform 0.15s;
}
.cover-action:hover span, .cover-action:focus-visible span { opacity: 1; transform: none; }
.cover-action:focus-visible { box-shadow: inset 0 0 0 3px var(--accent); }
/* No hover on touch screens, but the cover stays tappable and the card's own
   button says the same thing, so the pill would only repeat it. */
.badge {
  position: absolute; top: 8px; right: 8px;
  display: inline-flex; align-items: center; gap: 4px;
  padding: 3px 8px; border-radius: 999px;
  font-size: 11px; font-weight: 600;
  background: rgba(255, 255, 255, 0.92); color: #1d1d1f;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
  pointer-events: none;
  z-index: 2;
}
.badge svg.icon { width: 12px; height: 12px; stroke-width: 2.4; }
.badge.good { color: #1a7f37; }
.badge.warn { color: #9a5b00; }
.badge.bad { color: #c9162b; }
.badge.busy { color: #0058c7; }
.cover-progress {
  position: absolute; left: 0; right: 0; bottom: 0;
  height: 6px; background: rgba(0, 0, 0, 0.4);
  overflow: hidden;
  z-index: 2;
}
.cover-progress .fill { height: 100%; background: var(--accent); width: 0; transition: width 0.6s ease; }
.cover-progress.indeterminate .fill { width: 35%; animation: slide 1.5s ease-in-out infinite; }
@keyframes slide { 0% { transform: translateX(-100%); } 100% { transform: translateX(290%); } }
.card.working .cover::after {
  content: ""; position: absolute; inset: 0;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.35), transparent 45%);
  pointer-events: none;
}
.meta { padding-top: 10px; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.title {
  margin: 0; font-size: 13.5px; font-weight: 600; line-height: 1.3;
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
  overflow-wrap: anywhere;
}
.author { margin: 0; color: var(--muted); font-size: 12.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.state { font-size: 12px; color: var(--muted); margin-top: 4px; }
.state.good { color: var(--good); }
.state.warn { color: var(--warn); }
.state.bad { color: var(--bad); }
.state.busy { color: var(--accent); }
.state-detail { font-size: 12px; color: var(--muted); display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
.actions .btn { flex: 1 1 auto; }
.actions .btn.icon-only { flex: none; }
.tag { display: inline-block; font-size: 10.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--faint); }

/* -------------------------------------------------------- skeleton, empty */
.skeleton .cover { box-shadow: none; animation: shimmer 1.4s ease-in-out infinite; }
.skeleton .line { height: 10px; border-radius: 5px; background: var(--skeleton); margin-top: 10px; animation: shimmer 1.4s ease-in-out infinite; }
.skeleton .line.short { width: 60%; margin-top: 6px; }
@keyframes shimmer { 50% { opacity: 0.5; } }
.empty { text-align: center; padding: 64px 16px; color: var(--muted); }
.empty-icon { width: 52px; height: 52px; margin: 0 auto 14px; border-radius: 14px; display: grid; place-items: center; background: var(--track); color: var(--faint); }
.empty-icon svg.icon { width: 26px; height: 26px; }
.empty h2 { color: var(--text); font-size: 17px; margin: 0 0 6px; }
.empty p { margin: 0 auto 16px; max-width: 380px; }

/* ----------------------------------------------------------------- toasts */
.toasts {
  position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%);
  display: flex; flex-direction: column; gap: 8px; align-items: center;
  z-index: 50; width: min(440px, calc(100vw - 32px));
  pointer-events: none;
}
.toast {
  pointer-events: auto;
  display: flex; align-items: flex-start; gap: 10px;
  width: 100%;
  background: var(--surface); color: var(--text);
  border: 1px solid var(--border);
  border-left: 4px solid var(--accent);
  border-radius: 10px;
  box-shadow: var(--shadow-lift);
  padding: 10px 12px;
  font-size: 13px;
  animation: toast-in 0.2s ease-out;
}
.toast.bad { border-left-color: var(--bad); }
.toast.good { border-left-color: var(--good); }
.toast .toast-text { flex: 1; }
.toast .icon-btn { width: 22px; height: 22px; margin: -2px -4px 0 0; }
@keyframes toast-in { from { opacity: 0; transform: translateY(8px); } }
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; animation-iteration-count: 1 !important; transition-duration: 0.01ms !important; }
}
</style>
</head>
<body>
<header class="topbar">
  <div class="topbar-inner">
    <div class="brand">
      <div class="brand-mark" aria-hidden="true"><svg class="icon" viewBox="0 0 24 24"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5z"/><path d="M4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5"/></svg></div>
      <div class="brand-text">
        <div class="brand-name">Kindle Export</div>
        <div class="status" id="status" role="status" aria-live="polite"><span class="dot" id="status-dot"></span><span id="status-text">Starting…</span></div>
      </div>
    </div>
    <div class="tools">
      <label class="search">
        <span class="sr-only">Search your books</span>
        <svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
        <input type="search" id="search" placeholder="Search by title or author" autocomplete="off" spellcheck="false">
      </label>
      <button class="icon-btn" id="refresh-btn" type="button" title="Refresh your library" aria-label="Refresh your library">
        <svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/></svg>
      </button>
      <div class="menu-wrap">
        <button class="icon-btn" id="menu-btn" type="button" title="Settings" aria-label="Settings" aria-haspopup="true" aria-expanded="false" aria-controls="menu">
          <svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>
        </button>
        <div class="menu" id="menu" role="dialog" aria-label="Settings" hidden>
          <div class="menu-section">
            <label class="switch-row">
              <input type="checkbox" class="switch" id="pdf-switch" role="switch">
              <span class="switch-text">Also make a PDF
                <small>Every book is saved as a Markdown text file. Turn this on to get a PDF next to it too.</small></span>
            </label>
          </div>
          <div class="menu-section" id="menu-key" hidden>
            <p class="menu-label">OpenAI key</p>
            <form id="menu-key-form" class="key-form">
              <input type="password" id="menu-key-input" placeholder="Saved — paste a new key to replace it" autocomplete="off" aria-label="New OpenAI API key">
              <button class="btn" type="submit">Save</button>
            </form>
          </div>
          <div class="menu-section">
            <p class="menu-label">Books are saved in</p>
            <p class="menu-path" id="menu-outdir"></p>
            <button class="menu-item" id="menu-finder" type="button" hidden>
              <svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
              Show books in Finder
            </button>
          </div>
          <div class="menu-section">
            <button class="menu-item" id="menu-signin" type="button">
              <svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>
              <span id="menu-signin-text">Sign in to Amazon again</span>
            </button>
            <details id="log-details" style="margin-top:6px">
              <summary>Activity log</summary>
              <div class="log" id="log"></div>
            </details>
          </div>
        </div>
      </div>
    </div>
  </div>
</header>

<main>
  <div class="notices" id="notices"></div>
  <div class="filterbar" id="filterbar" hidden>
    <div class="segmented" role="group" aria-label="Show">
      <button type="button" id="filter-all" aria-pressed="true">All books</button>
      <button type="button" id="filter-done" aria-pressed="false">Exported</button>
    </div>
    <span class="filtercount" id="filtercount"></span>
  </div>
  <div class="grid" id="grid" aria-label="Your books"></div>
  <div class="empty" id="empty" hidden></div>
</main>

<div class="toasts" id="toasts" aria-live="polite"></div>

<script>
'use strict'

var state = null
var filter = 'all'
var cards = {}
var lastStatus = {}
var firstRender = true
var ICONS = {
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  alert: '<path d="M12 8v5"/><path d="M12 16.5v.01"/><path d="M10.3 3.9 2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  download: '<path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  x: '<path d="M6 6l12 12"/><path d="M18 6 6 18"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  window: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9"/><path d="m17 6 3 3"/>',
  book: '<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5z"/><path d="M4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  arrow: '<path d="M12 5v14"/><path d="m5 12 7 7 7-7"/>'
}

function $(id) { return document.getElementById(id) }

function el(tag, attrs) {
  var node = document.createElement(tag)
  attrs = attrs || {}
  for (var key in attrs) {
    var value = attrs[key]
    if (value === undefined || value === null || value === false) continue
    if (key === 'text') node.textContent = value
    else if (key === 'class') node.className = value
    else if (key === 'onclick') node.addEventListener('click', value)
    else node.setAttribute(key, value === true ? '' : value)
  }
  for (var i = 2; i < arguments.length; i++) {
    var child = arguments[i]
    if (child === undefined || child === null || child === false) continue
    node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child)
  }
  return node
}

/** Icons are fixed markup from ICONS above, never anything from the server. */
function icon(name) {
  var ns = 'http://www.w3.org/2000/svg'
  var svg = document.createElementNS(ns, 'svg')
  svg.setAttribute('class', 'icon')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('aria-hidden', 'true')
  svg.innerHTML = ICONS[name] || ''
  return svg
}

function toast(message, kind) {
  var holder = $('toasts')
  var close = el('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Dismiss' }, icon('x'))
  var node = el('div', { class: 'toast ' + (kind || 'bad'), role: kind === 'good' ? 'status' : 'alert' },
    el('div', { class: 'toast-text', text: message }), close)
  function dismiss() { if (node.parentNode) node.parentNode.removeChild(node) }
  close.addEventListener('click', dismiss)
  holder.appendChild(node)
  while (holder.children.length > 3) holder.removeChild(holder.firstChild)
  setTimeout(dismiss, kind === 'good' ? 5000 : 8000)
}

/*TRANSPORT*/

function ago(ms) {
  var s = Math.max(0, Math.round((Date.now() - ms) / 1000))
  if (s < 45) return 'just now'
  var m = Math.round(s / 60)
  if (m < 60) return m + ' min ago'
  var h = Math.round(m / 60)
  if (h < 24) return h + (h === 1 ? ' hour ago' : ' hours ago')
  var d = Math.round(h / 24)
  return d + (d === 1 ? ' day ago' : ' days ago')
}

function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many) }

function hueFor(text) {
  var h = 0
  for (var i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) % 360
  return h
}

function initials(title) {
  var words = String(title).split(' ').filter(function (w) {
    return w && /[A-Za-z0-9\\u00C0-\\uFFFF]/.test(w.charAt(0))
  })
  var skip = { the: 1, a: 1, an: 1 }
  if (words.length > 1 && skip[words[0].toLowerCase()]) words.shift()
  return words.slice(0, 2).map(function (w) { return w.charAt(0).toUpperCase() }).join('') || '?'
}

/** Cover URLs are checked on the server too; this is the last line. */
function safeCover(url) {
  return typeof url === 'string' && url.indexOf('https://') === 0 ? url : ''
}

// ------------------------------------------------------------------ model

function diskIndex() {
  var byAsin = {}
  state.diskBooks.forEach(function (b) { byAsin[b.asin] = b })
  return byAsin
}

function queueIndex() {
  var byAsin = {}
  var waiting = 0
  state.queue.books.forEach(function (entry) {
    if (entry.status === 'queued') entry.position = ++waiting
    byAsin[entry.asin] = entry
  })
  return byAsin
}

/**
 * Every book worth a card: the library in Amazon's order (most recent first),
 * then books on disk the library doesn't list (an older account, or a
 * library that hasn't loaded), then anything queued from neither.
 */
function allBooks(disk, queue) {
  var seen = {}
  var list = []
  var library = state.library ? state.library.books : []
  library.forEach(function (b) {
    seen[b.asin] = true
    list.push({ asin: b.asin, title: b.title, authors: b.authors || [], coverUrl: b.coverUrl, sample: !!(b.resourceType && b.resourceType.indexOf('SAMPLE') !== -1) })
  })
  state.diskBooks.forEach(function (d) {
    if (seen[d.asin]) return
    seen[d.asin] = true
    list.push({ asin: d.asin, title: d.title || d.asin, authors: d.authors || [] })
  })
  state.queue.books.forEach(function (q) {
    if (seen[q.asin]) return
    seen[q.asin] = true
    list.push({ asin: q.asin, title: q.title || q.asin, authors: [] })
  })
  return list
}

var ACTIVE = { working: 1, capturing: 1, transcribing: 1, exporting: 1 }

function newestExport(book, format) {
  var best = null
  if (!book) return best
  book.exports.forEach(function (f) {
    if (f.format === format && (!best || f.mtimeMs > best.mtimeMs)) best = f
  })
  return best
}

/**
 * What a card shows and offers, from the queue entry (what is happening now)
 * and the files on disk (what already exists). The queue wins while a book
 * is waiting or being exported; afterwards the files are the truth.
 */
function viewFor(book, disk, entry) {
  var view = { kind: 'idle', badge: null, label: '', detail: '', progress: undefined, actions: [], cover: null }
  var md = newestExport(disk, 'md')
  var pdf = newestExport(disk, 'pdf')
  var remedy = disk && disk.completeness.remedy

  if (entry && entry.status === 'queued') {
    view.kind = 'queued'
    view.badge = { kind: 'busy', icon: 'clock', text: entry.position === 1 ? 'Next' : 'Waiting' }
    view.label = entry.position === 1 ? 'Up next' : 'Waiting (' + entry.position + ' in line)'
    view.labelKind = 'busy'
    view.actions.push({ id: 'remove', text: 'Remove from queue', style: 'quiet' })
    return view
  }

  if (entry && ACTIVE[entry.status]) {
    view.kind = 'working'
    view.labelKind = 'busy'
    if (entry.status === 'capturing') {
      view.label = 'Capturing pages'
      // Compare the page reached, not screens captured: one page can span
      // several screens, which read as "page 210 of about 116".
      if (entry.capturedTotal && entry.capturedPage) {
        view.detail = 'Page ' + Math.min(entry.capturedPage, entry.capturedTotal) + ' of about ' + entry.capturedTotal
        view.progress = Math.min(1, entry.capturedPage / entry.capturedTotal)
      } else {
        view.detail = entry.captured ? plural(entry.captured, 'page', 'pages') + ' so far' : 'Opening the book…'
        view.progress = null
      }
    } else if (entry.status === 'transcribing') {
      view.label = 'Reading text'
      if (entry.transcribedTotal) {
        view.detail = (entry.transcribed || 0) + ' of ' + entry.transcribedTotal + ' pages'
        view.progress = Math.min(1, (entry.transcribed || 0) / entry.transcribedTotal)
      } else {
        view.progress = null
      }
    } else if (entry.status === 'exporting') {
      view.label = 'Building file'
      view.progress = null
    } else {
      view.label = 'Starting…'
      view.progress = null
    }
    if (state.queue.stopRequested) view.detail = (view.detail ? view.detail + ' · ' : '') + 'last book before stopping'
    return view
  }

  if (entry && entry.status === 'failed') {
    view.kind = 'attention'
    view.badge = { kind: 'bad', icon: 'alert', text: 'Failed' }
    view.label = 'Could not export'
    view.labelKind = 'bad'
    view.detail = entry.error || ''
    view.actions.push({ id: 'export', text: 'Try again', style: 'primary' })
    if (md) view.actions.push({ id: 'download', text: 'Download', file: md.name, iconOnly: true })
    return view
  }

  if (remedy) {
    view.kind = 'attention'
    view.badge = { kind: 'warn', icon: 'alert', text: 'Needs attention' }
    view.label = remedy === 'capture-again' ? 'Stopped part-way' : 'Some pages unreadable'
    view.labelKind = 'warn'
    view.detail = disk.completeness.summary || ''
    view.actions.push(remedy === 'capture-again'
      ? { id: 'recapture', text: 'Capture again', style: 'primary' }
      : { id: 'export', text: 'Retry missing pages', style: 'primary' })
    if (md) view.actions.push({ id: 'download', text: 'Download', file: md.name, iconOnly: true })
    return view
  }

  if (md || pdf) {
    view.kind = 'done'
    view.badge = { kind: 'good', icon: 'check', text: 'Exported' }
    view.label = 'Exported'
    view.labelKind = 'good'
    if (md) view.actions.push({ id: 'download', text: 'Download', file: md.name, style: 'primary' })
    if (pdf) view.actions.push({ id: 'download', text: md ? 'PDF' : 'Download PDF', file: pdf.name, style: md ? '' : 'primary' })
    if (!pdf && state.alsoPdf) view.actions.push({ id: 'pdf', text: 'Make PDF' })
    if (state.platform === 'darwin') view.actions.push({ id: 'reveal', text: 'Show in Finder', iconOnly: true })
    return view
  }

  if (disk && disk.completeness.capturedPages) {
    view.kind = 'partial'
    view.label = 'Not finished'
    view.labelKind = 'warn'
    view.actions.push({ id: 'export', text: 'Finish export', style: 'primary' })
    view.cover = 'Finish export'
    return view
  }

  // Tinted rather than solid: a whole library of solid buttons drowns out
  // the few cards that need something done.
  view.actions.push({ id: 'export', text: 'Export', style: 'tint' })
  view.cover = 'Export'
  return view
}

// ---------------------------------------------------------------- actions

function needsKeyFirst() {
  if (state.needsApiKey && !state.hasApiKey) {
    toast('Add your OpenAI key first — the box is at the top of the page.')
    return true
  }
  return false
}

function runAction(action, book, button) {
  function failed(err) {
    if (button) button.disabled = false
    toast(err.message)
  }

  if (action.id === 'export' || action.id === 'recapture' || action.id === 'pdf') {
    if (needsKeyFirst()) return
    var body = { asin: book.asin }
    if (action.id === 'recapture') body.forceCapture = true
    if (action.id === 'pdf') body.formats = ['md', 'pdf']
    if (button) button.disabled = true
    optimistic(book.asin)
    api('/api/export', body).catch(function (err) {
      failed(err)
      // Undo the optimistic "waiting" with what the server really has.
      reload()
    })
  } else if (action.id === 'remove') {
    if (button) button.disabled = true
    api('/api/queue/remove', { asin: book.asin }).catch(failed)
  } else if (action.id === 'reveal') {
    api('/api/reveal', { asin: book.asin }).catch(failed)
  }
}

/**
 * Show a clicked book as waiting before the server's answer arrives, so a
 * click always visibly does something; the next state broadcast replaces it.
 */
function optimistic(asin) {
  var exists = state.queue.books.some(function (q) { return q.asin === asin && (q.status === 'queued' || ACTIVE[q.status]) })
  if (exists) return
  state.queue.books = state.queue.books.filter(function (q) { return q.asin !== asin })
  state.queue.books.push({ asin: asin, title: asin, status: 'queued', warnings: [], outputs: [] })
  render()
}

function downloadPath(asin, name) {
  return '/api/download/' + encodeURIComponent(asin) + '/' + encodeURIComponent(name)
}

// ----------------------------------------------------------------- render

function render() {
  if (!state) return
  renderStatus()
  renderMenu()
  renderNotices()
  renderGrid()
  noticeFinishedBooks()
  firstRender = false
}

function renderStatus() {
  var text
  var dot = ''
  var count = state.library ? state.library.books.length : 0
  var updated = state.library ? ' · updated ' + ago(state.library.fetchedAt) : ''

  if (state.amazon === 'signing-in') {
    text = READER.signingInStatus
    dot = 'busy'
  } else if (state.busy === 'library') {
    text = state.library ? plural(count, 'book', 'books') + ' · checking for new books…' : 'Loading your library…'
    dot = 'busy'
  } else if (state.amazon === 'signed-out') {
    text = 'Not signed in to Amazon' + (state.library ? ' · ' + plural(count, 'book', 'books') + updated : '')
    dot = 'warn'
  } else if (state.library) {
    text = (state.amazon === 'signed-in' ? 'Signed in · ' : '') + plural(count, 'book', 'books') + updated
    dot = state.amazon === 'signed-in' ? 'good' : ''
  } else if (state.libraryError) {
    text = 'Library not loaded'
    dot = 'warn'
  } else {
    text = 'Starting…'
  }

  $('status-text').textContent = text
  $('status-dot').className = 'dot' + (dot ? ' ' + dot : '')

  var refresh = $('refresh-btn')
  refresh.disabled = !!state.busy && state.busy !== 'library'
  refresh.classList.toggle('spinning', state.busy === 'library')
  refresh.title = state.busy === 'export'
    ? 'The list can refresh once the export is done'
    : 'Refresh your library'
}

function renderMenu() {
  $('pdf-switch').checked = !!state.alsoPdf
  $('menu-outdir').textContent = state.outDir
  $('menu-finder').hidden = state.platform !== 'darwin'
  $('menu-key').hidden = !(state.needsApiKey && state.hasApiKey)
  var signin = $('menu-signin')
  signin.disabled = !!state.busy
  $('menu-signin-text').textContent = state.amazon === 'signed-in' ? 'Sign in to Amazon again' : 'Sign in to Amazon'

  var log = $('log')
  var entries = state.queue.log
  if (log.getAttribute('data-count') !== String(entries.length) || log.getAttribute('data-last') !== String(entries.length ? entries[entries.length - 1].time : 0)) {
    log.setAttribute('data-count', String(entries.length))
    log.setAttribute('data-last', String(entries.length ? entries[entries.length - 1].time : 0))
    log.textContent = entries.length ? '' : 'Nothing yet.'
    entries.forEach(function (entry) {
      log.appendChild(el('div', { class: entry.level === 'warn' ? 'warn' : '', text: entry.message }))
    })
    log.scrollTop = log.scrollHeight
  }
}

function notice(kind, iconName, title, text, actions) {
  var body = el('div', { class: 'notice-body' },
    el('div', { class: 'notice-title', text: title }),
    text ? el('div', { class: 'notice-text', text: text }) : null)
  var node = el('div', { class: 'notice ' + kind },
    el('div', { class: 'notice-icon', 'aria-hidden': 'true' }, icon(iconName)), body)
  if (actions && actions.length) {
    var holder = el('div', { class: 'notice-actions' })
    actions.forEach(function (a) { holder.appendChild(a) })
    node.appendChild(holder)
  }
  return node
}

var noticeFingerprint = ''

function renderNotices() {
  var holder = $('notices')
  var parts = []
  var q = state.queue
  var active = q.books.filter(function (b) { return ACTIVE[b.status] })[0]
  var waiting = q.books.filter(function (b) { return b.status === 'queued' }).length
  var needsKey = state.needsApiKey && !state.hasApiKey

  if (needsKey) parts.push('key')
  if (state.amazon === 'signing-in') parts.push('signing-in')
  else if (state.amazon === 'signed-out' && !state.busy) parts.push('signed-out')
  else if (state.amazon === 'signed-out') parts.push('signed-out-busy')
  if (state.amazonError) parts.push('amazon-error:' + state.amazonError)
  if (state.profileBusy) parts.push('profile-busy')
  else if (state.libraryError) parts.push('library-error:' + state.libraryError)
  if (active || waiting) parts.push('queue:' + (active ? active.asin + active.status : '') + ':' + waiting + ':' + q.stopRequested + ':' + state.busy)

  var fingerprint = parts.join('|')
  if (fingerprint === noticeFingerprint) return
  noticeFingerprint = fingerprint

  // The key form keeps what was typed across re-renders.
  var typed = $('key-input') ? $('key-input').value : ''
  var hadFocus = document.activeElement && document.activeElement.id === 'key-input'
  holder.textContent = ''

  if (needsKey) {
    var input = el('input', { type: 'password', id: 'key-input', placeholder: 'sk-…', autocomplete: 'off', 'aria-label': 'OpenAI API key' })
    input.value = typed
    var form = el('form', {}, input, el('button', { class: 'btn primary', type: 'submit', text: 'Save key' }))
    form.addEventListener('submit', function (event) {
      event.preventDefault()
      saveKey(input.value, function () { input.value = '' })
    })
    var keyNotice = notice('warn', 'key', 'Add your OpenAI key to start',
      state.localOcr
        ? 'This app was started with an OpenAI model, so pages are read by OpenAI rather than on this computer. The key is stored only on this computer.'
        : "Reading a book's pages uses OpenAI and costs a little money — usually well under a dollar a book. The key is stored only on this computer.")
    keyNotice.appendChild(form)
    holder.appendChild(keyNotice)
    if (hadFocus) input.focus()
  }

  if (state.amazon === 'signing-in') {
    if (READER.signingIn) holder.appendChild(notice('', 'window', READER.signingIn.title, READER.signingIn.text))
  } else if (state.amazon === 'signed-out') {
    holder.appendChild(notice('warn', 'user', 'Sign in to Amazon to see your books', READER.signIn,
      [el('button', { class: 'btn primary', type: 'button', text: 'Sign in to Amazon', disabled: !!state.busy, onclick: signIn })]))
  }

  if (state.amazonError) {
    holder.appendChild(notice('warn', 'alert', 'Could not open the sign-in window', state.amazonError))
  }

  if (state.profileBusy) {
    holder.appendChild(notice('warn', 'clock', 'Chrome is busy with another Kindle Export',
      'Another copy of Kindle Export is using the browser right now. Your library will load as soon as it’s done — it tries again by itself.',
      [el('button', { class: 'btn', type: 'button', text: 'Try now', onclick: refreshLibrary })]))
  } else if (state.libraryError) {
    holder.appendChild(notice('bad', 'alert', 'Could not load your library', state.libraryError,
      [el('button', { class: 'btn', type: 'button', text: 'Try again', disabled: !!state.busy, onclick: refreshLibrary })]))
  }

  if (active || waiting) {
    var title
    var text
    if (active) {
      title = 'Exporting “' + titleOf(active.asin, active.title) + '”'
      text = active.status === 'capturing' || active.status === 'working'
        ? READER.reading
        : 'Almost there — the pages are captured and are being turned into text.'
      if (waiting) text += ' ' + plural(waiting, 'more book', 'more books') + ' waiting.'
    } else {
      title = plural(waiting, 'book', 'books') + ' waiting'
      text = state.busy === 'login'
        ? 'Exporting starts once you have signed in to Amazon.'
        : state.busy === 'library'
          ? 'Exporting starts as soon as your library has finished loading.'
          : 'Starting…'
    }
    var stop = null
    if (active) {
      stop = el('button', { class: 'btn', type: 'button', text: q.stopRequested ? 'Stopping after this book…' : 'Stop after this book', disabled: q.stopRequested })
      stop.addEventListener('click', function () {
        stop.disabled = true
        api('/api/queue/stop').catch(function (err) { stop.disabled = false; toast(err.message) })
      })
    }
    holder.appendChild(notice('', 'arrow', title, text, stop ? [stop] : []))
  }
}

function titleOf(asin, fallback) {
  var lib = state.library ? state.library.books : []
  for (var i = 0; i < lib.length; i++) if (lib[i].asin === asin) return lib[i].title
  return fallback || asin
}

function renderGrid() {
  var grid = $('grid')
  var disk = diskIndex()
  var queue = queueIndex()
  var books = allBooks(disk, queue)
  var needle = $('search').value.trim().toLowerCase()

  var exportedCount = books.filter(function (b) { return isOnDisk(disk[b.asin]) }).length
  $('filterbar').hidden = !books.length
  $('filter-all').setAttribute('aria-pressed', String(filter === 'all'))
  $('filter-done').setAttribute('aria-pressed', String(filter === 'done'))
  $('filter-done').textContent = 'Exported' + (exportedCount ? ' (' + exportedCount + ')' : '')

  var shown = books.filter(function (b) {
    if (filter === 'done' && !isOnDisk(disk[b.asin]) && !queue[b.asin]) return false
    if (!needle) return true
    return (b.title + ' ' + b.authors.join(' ')).toLowerCase().indexOf(needle) !== -1
  })

  $('filtercount').textContent = needle || filter === 'done'
    ? plural(shown.length, 'book', 'books') + ' shown'
    : ''

  if (!books.length) {
    renderEmptyLibrary(grid)
    return
  }

  grid.querySelectorAll('.skeleton').forEach(function (n) { n.remove() })

  var visible = {}
  shown.forEach(function (book, index) {
    visible[book.asin] = true
    var card = cards[book.asin] || (cards[book.asin] = createCard(book))
    updateCard(card, book, viewFor(book, disk[book.asin], queue[book.asin]))
    if (grid.children[index] !== card.root) grid.insertBefore(card.root, grid.children[index] || null)
  })
  Object.keys(cards).forEach(function (asin) {
    if (!visible[asin] && cards[asin].root.parentNode) cards[asin].root.parentNode.removeChild(cards[asin].root)
  })

  var empty = $('empty')
  if (shown.length) {
    empty.hidden = true
  } else {
    empty.hidden = false
    empty.textContent = ''
    empty.appendChild(needle
      ? emptyState('search', 'No books match “' + $('search').value.trim() + '”', 'Try part of the title or the author’s last name.')
      : emptyState('book', 'Nothing exported yet', 'Click any book in “All books” to export it. It shows up here when it’s done.'))
  }
}

function isOnDisk(d) {
  return !!(d && (d.exports.length || d.completeness.capturedPages))
}

function renderEmptyLibrary(grid) {
  var empty = $('empty')
  var loading = state.busy === 'library' || state.busy === 'login' ||
    (!state.library && state.amazon === 'unknown' && !state.libraryError && !state.amazonError)

  if (loading) {
    empty.hidden = true
    if (!grid.querySelector('.skeleton')) {
      grid.textContent = ''
      for (var i = 0; i < 12; i++) {
        grid.appendChild(el('div', { class: 'card skeleton', 'aria-hidden': 'true' },
          el('div', { class: 'cover' }), el('div', { class: 'line' }), el('div', { class: 'line short' })))
      }
    }
    return
  }

  grid.textContent = ''
  empty.hidden = false
  empty.textContent = ''
  if (state.amazon === 'signed-out') {
    empty.appendChild(emptyState('user', 'Your books will appear here', 'Sign in to Amazon above and your Kindle library shows up here. Then click a book to export it.'))
  } else if (state.library) {
    empty.appendChild(emptyState('book', 'No books in this Kindle library', 'Books you buy or borrow on Kindle show up here.',
      el('button', { class: 'btn', type: 'button', text: 'Check again', onclick: refreshLibrary })))
  } else {
    empty.appendChild(emptyState('book', 'Your library isn’t loaded yet', '',
      el('button', { class: 'btn primary', type: 'button', text: 'Load my books', disabled: !!state.busy, onclick: refreshLibrary })))
  }
}

function emptyState(iconName, title, text, action) {
  return el('div', {},
    el('div', { class: 'empty-icon', 'aria-hidden': 'true' }, icon(iconName)),
    el('h2', { text: title }),
    text ? el('p', { text: text }) : null,
    action || null)
}

function createCard(book) {
  var cover = el('div', { class: 'cover' })
  var placeholder = el('div', { class: 'placeholder', 'aria-hidden': 'true' },
    el('div', { class: 'initials', text: initials(book.title) }),
    el('div', { class: 'ph-title', text: book.title }))
  placeholder.style.setProperty('--hue', String(hueFor(book.asin + book.title)))
  cover.appendChild(placeholder)

  var src = safeCover(book.coverUrl)
  if (src) {
    var img = el('img', { alt: '', loading: 'lazy', decoding: 'async', referrerpolicy: 'no-referrer', src: src })
    img.addEventListener('error', function () { img.remove() })
    cover.appendChild(img)
  }

  var title = el('h3', { class: 'title', text: book.title, title: book.title })
  var author = el('p', { class: 'author', text: book.authors.join(', ') })
  var stateLine = el('div', { class: 'state' })
  var detail = el('div', { class: 'state-detail' })
  var actions = el('div', { class: 'actions' })
  var meta = el('div', { class: 'meta' }, title, author, stateLine, detail, actions)
  var root = el('article', { class: 'card', 'data-asin': book.asin }, cover, meta)

  return {
    root: root, cover: cover, title: title, author: author, stateLine: stateLine, detail: detail,
    actions: actions, coverUrl: src, sig: '', badge: null, bar: null, coverBtn: null
  }
}

function updateCard(card, book, view) {
  // The library may have filled in a title or cover the disk scan didn't know.
  if (card.title.textContent !== book.title) {
    card.title.textContent = book.title
    card.title.title = book.title
  }
  var authors = book.authors.join(', ')
  if (card.author.textContent !== authors) card.author.textContent = authors
  var src = safeCover(book.coverUrl)
  if (src && src !== card.coverUrl) {
    card.coverUrl = src
    var old = card.cover.querySelector('img')
    if (old) old.remove()
    var img = el('img', { alt: '', loading: 'lazy', decoding: 'async', referrerpolicy: 'no-referrer', src: src })
    img.addEventListener('error', function () { img.remove() })
    card.cover.insertBefore(img, card.cover.children[1] || null)
  }

  card.root.className = 'card ' + view.kind

  // Progress changes every few seconds; only the bar and text follow it.
  if (view.progress !== undefined) {
    if (!card.bar) {
      card.bar = el('div', { class: 'cover-progress', role: 'progressbar', 'aria-label': 'Export progress' }, el('div', { class: 'fill' }))
      card.cover.appendChild(card.bar)
    }
    card.bar.className = 'cover-progress' + (view.progress === null ? ' indeterminate' : '')
    card.bar.firstChild.style.width = view.progress === null ? '' : Math.round(view.progress * 100) + '%'
    if (view.progress === null) card.bar.removeAttribute('aria-valuenow')
    else card.bar.setAttribute('aria-valuenow', String(Math.round(view.progress * 100)))
  } else if (card.bar) {
    card.bar.remove()
    card.bar = null
  }

  card.stateLine.className = 'state' + (view.labelKind ? ' ' + view.labelKind : '')
  var label = view.label || (book.sample ? 'Sample' : '')
  if (card.stateLine.textContent !== label) card.stateLine.textContent = label
  card.stateLine.hidden = !label
  if (card.detail.textContent !== view.detail) card.detail.textContent = view.detail
  card.detail.hidden = !view.detail

  var sig = JSON.stringify([view.badge, view.actions, view.cover, state.needsApiKey && !state.hasApiKey, state.platform])
  if (sig === card.sig) return
  card.sig = sig

  if (card.badge) { card.badge.remove(); card.badge = null }
  if (view.badge) {
    card.badge = el('span', { class: 'badge ' + view.badge.kind }, icon(view.badge.icon), view.badge.text)
    card.cover.appendChild(card.badge)
  }

  // Rebuilding the buttons would drop keyboard focus; put it back on the
  // same action if it still exists, or on the card's first button.
  var focused = document.activeElement
  var focusAction = focused && card.root.contains(focused) ? focused.getAttribute('data-action') || 'cover' : null

  if (card.coverBtn) { card.coverBtn.remove(); card.coverBtn = null }
  if (view.cover) {
    card.coverBtn = el('button', { class: 'cover-action', type: 'button', 'data-action': 'cover', 'aria-label': view.cover + ' “' + book.title + '”' },
      el('span', {}, icon('download'), view.cover))
    card.coverBtn.addEventListener('click', function () { runAction({ id: 'export' }, book) })
    card.cover.appendChild(card.coverBtn)
  }

  card.actions.textContent = ''
  view.actions.forEach(function (action) {
    var node
    var cls = 'btn' + (action.style ? ' ' + action.style : '') + (action.iconOnly ? ' icon-only' : '')
    var label = action.iconOnly ? action.text + ' “' + book.title + '”' : null
    if (action.id === 'download') {
      node = downloadControl({ class: cls, 'data-action': 'download-' + action.file, 'aria-label': label, title: action.iconOnly ? action.text : null }, book.asin, action.file)
      node.appendChild(action.iconOnly ? icon('download') : document.createTextNode(action.text))
    } else {
      node = el('button', { class: cls, type: 'button', 'data-action': action.id, 'aria-label': label, title: action.iconOnly ? action.text : null })
      node.appendChild(action.iconOnly ? icon(action.id === 'reveal' ? 'folder' : 'download') : document.createTextNode(action.text))
      node.addEventListener('click', function () { runAction(action, book, node) })
    }
    card.actions.appendChild(node)
  })

  if (focusAction) {
    var target = card.root.querySelector('[data-action="' + focusAction + '"]') || card.root.querySelector('button, a')
    if (target) target.focus()
  }
}

/**
 * Say so when a book finishes: the card changes quietly, and someone who
 * walked away for the hour a capture takes should not have to hunt for it.
 */
function noticeFinishedBooks() {
  state.queue.books.forEach(function (entry) {
    var before = lastStatus[entry.asin]
    lastStatus[entry.asin] = entry.status
    if (firstRender || !before || before === entry.status) return
    if (!ACTIVE[before]) return
    var name = '“' + titleOf(entry.asin, entry.title) + '”'
    if (entry.status === 'done') toast(name + ' is ready to download.', 'good')
    else if (entry.status === 'warning') toast(name + ' is exported, but needs attention — see its card.', 'bad')
    else if (entry.status === 'failed') toast(name + ' could not be exported: ' + (entry.error || 'unknown error'), 'bad')
  })
}

// ------------------------------------------------------------------ wiring

function signIn() {
  api('/api/login').catch(function (err) { toast(err.message) })
}

function refreshLibrary() {
  api('/api/library').catch(function (err) { toast(err.message) })
}

function saveKey(key, done) {
  key = String(key || '').trim()
  if (!key) { toast('Paste your OpenAI key first.'); return }
  api('/api/config', { apiKey: key }).then(function () {
    if (done) done()
    toast('Key saved.', 'good')
  }).catch(function (err) { toast(err.message) })
}

$('refresh-btn').addEventListener('click', refreshLibrary)

$('search').addEventListener('input', function () { if (state) renderGrid() })

$('filter-all').addEventListener('click', function () { filter = 'all'; renderGrid() })
$('filter-done').addEventListener('click', function () { filter = 'done'; renderGrid() })

function setMenu(open) {
  $('menu').hidden = !open
  $('menu-btn').setAttribute('aria-expanded', String(open))
}

$('menu-btn').addEventListener('click', function (event) {
  event.stopPropagation()
  var open = $('menu').hidden
  setMenu(open)
  if (open) $('pdf-switch').focus()
})

document.addEventListener('click', function (event) {
  if (!$('menu').hidden && !$('menu').contains(event.target)) setMenu(false)
})

document.addEventListener('keydown', function (event) {
  if (event.key === 'Escape') {
    if (!$('menu').hidden) {
      setMenu(false)
      $('menu-btn').focus()
    } else if (document.activeElement === $('search') && $('search').value) {
      $('search').value = ''
      renderGrid()
    }
  }
  // The Mac app's window has no find bar, so Cmd-F goes to the search box.
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') {
    event.preventDefault()
    $('search').focus()
    $('search').select()
  }
})

$('pdf-switch').addEventListener('change', function () {
  var on = $('pdf-switch').checked
  api('/api/config', { alsoPdf: on }).then(function () {
    toast(on ? 'New exports will include a PDF.' : 'New exports will be Markdown only.', 'good')
  }).catch(function (err) {
    $('pdf-switch').checked = !on
    toast(err.message)
  })
})

$('menu-key-form').addEventListener('submit', function (event) {
  event.preventDefault()
  saveKey($('menu-key-input').value, function () { $('menu-key-input').value = '' })
})

$('menu-finder').addEventListener('click', function () {
  setMenu(false)
  api('/api/reveal', {}).catch(function (err) { toast(err.message) })
})

$('menu-signin').addEventListener('click', function () {
  setMenu(false)
  signIn()
})

// "Updated 2 min ago" has to keep moving even when nothing else does.
setInterval(function () { if (state) renderStatus() }, 30000)

listenForState()
reload(true)
</script>
</body>
</html>
`
