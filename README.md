# Book Export for Kindle

Export Kindle books you own as clean markdown. On a Mac it runs entirely on
your own machine — no API key, no network calls beyond Amazon, nothing to pay
for.

It is for books you have bought, for your own reading. It works against
Amazon's terms of service, and exports must not be shared — read
[Scope](#scope) before using it.

- **On a Mac: `Book Export for Kindle.app`.** A native app of a few megabytes — click
  a book in your library and it becomes a Markdown file (or a PDF). It
  carries its own command-line tool, `book-export`, for the terminal.
  Neither needs Node or Chrome.
- **Anywhere else: the legacy Node CLI** (Node + Chrome), which only gets
  fixes now — see [Legacy Node CLI](#legacy-node-cli-unsupported).

## On a Mac: Book Export for Kindle.app

`pnpm package` builds `Book Export for Kindle.app` — a native Mac app of a few
megabytes that needs nothing else installed: no Node, no Chrome, no API key.
It runs on macOS 13 or later, and it is made so that someone who never
touches a terminal can use it alone.

```bash
pnpm package                  # this Mac's architecture
ARCH=universal pnpm package   # Apple silicon and Intel in one app (needs Xcode)
```

Building it needs this repo's dev setup (Node and pnpm, plus Xcode or its
command line tools); the app it produces needs none of it. It lands in
`dist-app/`. Copy it to the other Mac's `/Applications`, then right-click →
**Open** → **Open** once — it is signed ad hoc, not notarised, so the first
launch needs that; afterwards it opens with a normal double-click.

It shows your Kindle library in a single window: click a book to export it;
clicking more lines them up. Each book's card says where it is — capturing
(page x of y), reading text, done — and a book that finished short says so
and offers the fix (**Capture again**, **Retry missing pages**). When
Amazon needs you to sign in, that window shows Amazon's own sign-in page under
a small bar with a **Cancel** button (sign in as you always do; it stays signed
in between launches), and switches back to your library by itself once you're
in. The pages of a book are turned out of sight — you can keep using your Mac
while it reads. Pages are read with Apple's Vision framework
on the Mac itself. Books are written to `~/Documents/Kindle Export`, and
**Download** saves a copy to `~/Downloads` and shows it in Finder. Quitting
while a book is being exported asks first.

Under the hood the app is Swift (WebKit for the reader and the page, Vision for
the text, JavaScriptCore for the rest): the logic that turns captured pages
into a book — table of contents, page numbering, paragraph reconstruction,
Markdown and PDF layout — is the same TypeScript the Node CLI runs, bundled into
`kindle-core.js` and evaluated in JavaScriptCore, so both write identical files
and can finish each other's books. See [`macos/PLAN.md`](macos/PLAN.md) for the
design and the page ↔ app bridge.

### Command line on macOS

The app carries a native `book-export` command — the same engine (WebKit
reader, Vision OCR, the shared TypeScript logic in JavaScriptCore), so the
terminal needs no Node or Chrome either. Install it from the app's menu:
**Book Export for Kindle › Install Command-Line Tool…** puts a `book-export` link in
`/usr/local/bin` (or `~/.local/bin` when `/usr/local/bin` needs an
administrator — the alert then shows the one `sudo` line to paste if you want
it there; the app never asks for your password). **Uninstall Command-Line
Tool…** removes it again. Without installing, run it from the bundle:
`"/Applications/Book Export for Kindle.app/Contents/MacOS/book-export"`.

```
book-export                          pick books from your library, then export
book-export <ASIN...>                capture, transcribe and export (resumes)
book-export login                    sign in to Amazon (in a window)
book-export list [--json] [--limit n]
book-export clean [ASIN...]          delete working files, keeping the text
book-export capture <ASIN...>        capture page images only
book-export ocr <ASIN...>            transcribe captured pages only
book-export export <ASIN...>         write markdown/PDF from transcribed text only
```

Options: `--format md,pdf`, `--out-dir <dir>`, `--concurrency <n>`,
`--force`, `--force-capture`, `--force-ocr`, `--keep-pages`, `--show` (watch
the reader turn pages instead of doing it out of sight), `-h`/`--help`,
`-v`/`--version`.

It is the app's command line, not a separate tool:

- **Same sign-in.** WebKit keeps a Mac app's cookies per bundle identifier,
  and the tool lives inside the app bundle (`Contents/MacOS/book-export`)
  and runs as the app — through the PATH link it re-executes itself from the
  real path so it does. Signing in in either signs in both. If Amazon wants a
  sign-in mid-run, its page opens in a window (and a Dock icon appears for as
  long as it's open); otherwise the tool stays out of the Dock and never takes
  focus. Without a terminal to answer (a script, cron), it fails with a hint
  to run `book-export login` instead of waiting for someone.
- **Same books.** Books go to `~/Documents/Kindle Export` unless `--out-dir`
  says otherwise, so a book started in the terminal shows up in the app and the
  other way round. The per-book lock keeps the two from working on the same
  book at once. (The Node CLI's default is `./out`.)
- **Pick, don't hunt for ASINs.** With no ASINs it reads your library and
  shows a numbered list (with a filter prompt first when the library is long);
  type `1 3 5-7` or `all`.
- **Exit status.** Non-zero when any book failed or came out short (a capture
  that stopped early, pages that couldn't be read). Ctrl-C stops cleanly: the
  capture is recorded as interrupted, the book's lock is released, and a second
  Ctrl-C quits at once.

Quit the app while the tool captures (and the other way round): both drive the
same Amazon session.

## How it works

Kindle Cloud Reader renders each page as an image, so there is no text layer to
read. The pipeline is three stages:

1. **capture** — drives the Kindle reader through the book (a WebKit view in
   the app, Chrome in the Node CLI), saving one image per rendered page plus
   the table of contents and metadata.
2. **transcribe** — reads the text off each page image and stores it in
   `content.json`. On macOS this uses Apple's Vision framework locally;
   the Node CLI elsewhere, or with `--model`, uses an OpenAI vision model.
3. **export** — reassembles the text into markdown.

Re-running skips any stage whose output already exists, but how much of a
half-finished book survives depends on the stage. When the Kindle reader stops
turning pages mid-capture, the capture reloads it, returns to the last page it
saved and carries on, up to three times. A capture that still can't finish, or
whose run was interrupted, cannot be continued later: it is reported as
incomplete, and the book has to be captured again from the beginning with
`--force-capture` (the app shows a **Capture again** button on such a book
instead). Transcription
resumes at page granularity — if some pages fail, re-running retries only
those, rather than paying to read the whole book again. Export is regenerated
from `content.json` whenever it is asked for, so it costs nothing to redo. Use
`--force-ocr` (or `--force`) to redo a stage deliberately.

Pages that could never be read are listed explicitly and the command exits
non-zero — an export with holes in it isn't success, even though a file was
written.

## Output

One folder per book — in `~/Documents/Kindle Export` for the app and its
command line, in `./out` for the legacy Node CLI (both write the same files, so
either can finish a book the other started):

```
<ASIN>/
  metadata.json    title, authors, table of contents, page index
  pages/           one PNG per rendered page
  content.json     transcribed text, one chunk per page, tagged with the capture it came from
  <title>.md       the finished markdown
```

## Text quality

Transcribing page-by-page introduces two artefacts that
[`postprocess-text.ts`](src/postprocess-text.ts) repairs deterministically:

- **Paragraphs split across page boundaries.** 20–40% of pages end mid-sentence;
  those halves are rejoined. The join only happens when the previous page ends
  mid-sentence _and_ the next begins lowercase — a missed join reads as it does
  today, whereas a wrong join welds unrelated paragraphs together.
- **Flattened headings.** Section headings arrive as ordinary all-caps
  paragraphs and are promoted back to markdown headings.

Rules a PDF pipeline would need are deliberately absent — this corpus has no
line-ending hyphens, no standalone page numbers, and no running heads, and
stripping repeated page-edge lines would eat real chapter headings.

Section boundaries come from the table of contents, matched against headings
found in the text ([`toc-sections.ts`](src/toc-sections.ts)). Kindle page
numbers are coarse and sometimes numbered on a different scale from the
captured pages, so the label match is what actually pins a chapter down.

## Limitations

- **Transcription is OCR**, so it is not perfectly faithful. Apple's Vision
  framework applies language correction, which resolves ambiguous glyphs
  against a dictionary — measured over a 126-page book it altered 62 pages and
  touched a digit exactly once, so on prose it fixes far more than it invents.
  An isolated number with no surrounding words is where it errs.
- **Off macOS, transcription is a paid model call.** Budget roughly one call
  per page.
- **Some books section poorly.** Where the table of contents is numbered in
  Kindle locations rather than pages, and chapter titles wrap across lines,
  fewer chapters are matched and sections run long. No text is lost — every
  page lands in exactly one section.
- **Login is interactive.** Amazon may challenge the session; that is by design
  and the reason this is a local tool rather than a service.

## Legacy Node CLI (unsupported)

The original command-line tool, in Node with a Chrome window for the reader
(`src/cli.ts`, `pnpm book-export`). On macOS it is superseded by the app and
its `book-export` command above; it stays because it is **the only option
off macOS** (with OpenAI reading the pages there), and it gets fixes only — no
new features. Its books go to `./out` by default, and its Amazon session is a
Chrome profile of its own (`~/.kindle-export/profile`), separate from the app's.
Both are called `book-export`: on a Mac that has the app's command, run the
Node one as `pnpm book-export` rather than `npm link`-ing it over the other
(the app's installer won't replace an existing `book-export` link it didn't
make).

### Install

Requires Node 20+. Uses Google Chrome if installed, otherwise Playwright's
bundled Chromium. On macOS, the Xcode command line tools
(`xcode-select --install`) enable free local OCR; without them the build still
succeeds and transcription falls back to OpenAI.

```bash
git clone https://github.com/sjoblom/kindle-export
cd book-export
pnpm install
pnpm build
npm link          # optional: puts `book-export` on your PATH
```

Without `npm link`, run it as `pnpm book-export <args>`.

There is nothing you have to configure on macOS. `book-export setup` asks
where books should go and offers to sign in to Amazon; off macOS it also asks
for the OpenAI key that reading pages needs there. Both are stored in
`~/.kindle-export/config.json`:

```bash
book-export setup
```

(A key in `.env` or the environment also works and takes precedence; the web
app's Settings screen writes the same stored config.)

Sign in once. This opens a browser, lets you complete login and 2FA
yourself, and stores the session under `~/.kindle-export/profile`:

```bash
book-export login
```

**You never give this tool your Amazon password.** If the stored session
expires, a browser window opens on Amazon's own sign-in page and you sign in by
hand there.

#### What leaves your machine

On macOS, in the default configuration: **nothing**. Pages are read locally by
Apple's Vision framework, your Amazon session stays in a local browser profile,
and the text and images stay in `out/`. The only network traffic is with Amazon
itself, to read the book you already own.

Passing `--model` or setting `OCR_MODEL` (or running off macOS) sends every
page image to OpenAI to be transcribed instead. That costs roughly one
vision-model call per page — a few tens of cents for a 300-page book on
`gpt-4.1-mini`, the model used off macOS unless you name another.

#### Platform support

Developed and tested on **macOS**, where it also reads pages locally. It uses
Google Chrome when installed and falls back to Playwright's bundled Chromium
otherwise, which should cover Linux and containers — but that fallback path is
**untested**, so treat Linux and Windows as unverified rather than supported.
Off macOS, transcription requires an OpenAI key. Set `BROWSER_CHANNEL` to pick
a specific channel (`chrome`, `msedge`, …) or leave it unset for the default.
Reports welcome.

### Usage

```
book-export serve                    open the web app in your browser
book-export                          pick books from your library, then export
book-export <ASIN...>                capture, transcribe and export
book-export login                    sign in once, storing the session
book-export list                     list the books in your Kindle library
book-export capture <ASIN...>        capture page images only
book-export ocr <ASIN...>            transcribe captured pages only
book-export export <ASIN...>         render markdown from transcribed text only
```

Useful options: `--format md,pdf`, `--json` and `--limit` for `list`,
`--port` for `serve`, plus `--out-dir`, `--profile-dir`, `--model`,
`--concurrency` and `--force`. Run `book-export --help` for the
full list.

`--model <name>` (or `OCR_MODEL` in the environment or `.env`) switches
transcription from local OCR to an OpenAI model, which needs an API key. It is
deliberately a per-run choice rather than a stored setting, so a Mac never
starts paying for what it can read for free; `book-export serve --model ...`
applies it to the web app too. Leave it unset on macOS.

`list` reads the same internal JSON endpoint the Kindle library page uses, so
it sees everything in your account and pages through it.

The ASIN is also in the Amazon URL for a book — `.../dp/B01H4G2J1U`.

### The web app

`book-export serve` opens a local page in your browser — made so that
someone who never touches a terminal can use this after a one-time install.
There are no steps to work through; the page is your Kindle library:

- **It loads by itself.** The list from the last launch shows straight away,
  and a minimized Chrome window refreshes it in the background. If Amazon
  says nobody is signed in, its sign-in page opens once, by itself: sign in
  there the way you always do (password, any code Amazon sends) and the
  window closes itself. The app never sees the password. After that, a
  **Sign in to Amazon** button is there if it's needed again.
- **Click a book to export it.** Clicking more books while one is exporting
  lines them up behind it; a waiting book can be taken off the queue, and
  **Stop after this book** clears the queue without cutting the current
  capture short. Capture happens in a minimized Chrome window that turns the
  pages by itself and pops up only if Amazon wants a sign-in.
- **Each book's card says where it is** — waiting, capturing (page x of y),
  reading text, building the file, done — and finished books have a
  **Download** button (and **Show in Finder** on macOS), including books
  exported in earlier runs. A book that finished short says so honestly and
  offers the fix: **Capture again** when the capture stopped part-way,
  **Retry missing pages** when some pages couldn't be read.

Books are saved as Markdown. The settings menu (the gear) has a switch to
also make a PDF of each book, shows where books are saved, and can sign in to
Amazon again. The library list is cached inside the browser profile
(`kindle-export-library.json`), so it belongs to the signed-in account and
goes away with the profile.

On macOS there is nothing else to set up: pages are read on the Mac itself, so
there is no key to enter and no model to choose. Off macOS (or without the
Xcode tools that build local OCR), the page first asks for an OpenAI API key,
stored in `~/.kindle-export/config.json` and readable only by you.

The server binds `127.0.0.1` only — nothing is reachable from the network —
and rejects requests whose `Host` or headers don't come from its own page.
Everything the CLI can do beyond this (per-stage commands, `--force`,
cleanup) still works from the terminal; the two share one pipeline and
one on-disk state, so you can mix them freely.

## Scope

This is for exporting books **you have purchased**, for your own reading,
research and archival use. Automating Kindle Cloud Reader is contrary to
Amazon's terms of service, and using it may put your Amazon account at risk —
that risk is yours to weigh. Don't redistribute what it produces; the output is
copyrighted material belonging to its authors and publishers.

Not affiliated with, endorsed by, or connected to Amazon. "Kindle" is a
trademark of Amazon.com, Inc.

## Credits

A fork of [kindle-ai-export](https://github.com/transitive-bullshit/kindle-ai-export)
by Travis Fischer, MIT licensed. This fork adds a unified CLI, library listing
and selection, resumable stages, deterministic text post-processing,
table-of-contents section resolution, free local OCR on macOS, a local web app
and a double-clickable macOS bundle.

Licensed under the [MIT License](LICENSE).
