# kindle-export

Export Kindle books you own as clean markdown. On macOS it runs entirely on
your own machine — no API key, no network calls, nothing to pay for.

```bash
kindle-export serve          # the web app — everything in your browser
```

or, in the terminal:

```bash
kindle-export login          # once
kindle-export                # pick books from your library, then export
```

No need to hunt for ASINs — running it with no arguments reads your Kindle
library and shows a menu you can select one or many books from. If you already
know the ASIN, pass it directly: `kindle-export B01H4G2J1U`.

## The web app

`kindle-export serve` opens a local page in your browser — made so that
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

### A double-clickable Mac app

For someone who shouldn't have to see a terminal at all, `pnpm package` builds
`Kindle Export.app` — a native Mac app of a few megabytes that needs nothing
else installed: no Node, no Chrome, no API key. It runs on macOS 13 or later.

```bash
pnpm package                  # this Mac's architecture
ARCH=universal pnpm package   # Apple silicon and Intel in one app (needs Xcode)
```

Building it needs this repo's dev setup (Node and pnpm, plus Xcode or its
command line tools); the app it produces needs none of it. It lands in
`dist-app/`. Copy it to the other Mac's `/Applications`, then right-click →
**Open** → **Open** once — it is signed ad hoc, not notarised, so the first
launch needs that; afterwards it opens with a normal double-click.

It shows the same page as `kindle-export serve`, in its own window. Amazon
sign-in happens in a second window inside the app (sign in there as you always
do; it stays signed in between launches), and the same window turns the pages
during a capture, out of the way. Pages are read with Apple's Vision framework
on the Mac itself. Books are written to `~/Documents/Kindle Export`, and
**Download** saves a copy to `~/Downloads` and shows it in Finder. Quitting
while a book is being exported asks first.

Under the hood the app is Swift (WebKit for the reader and the page, Vision for
the text, JavaScriptCore for the rest): the logic that turns captured pages
into a book — table of contents, page numbering, paragraph reconstruction,
Markdown and PDF layout — is the same TypeScript the CLI runs, bundled into
`kindle-core.js` and evaluated in JavaScriptCore, so both write identical files
and can finish each other's books. See [`macos/PLAN.md`](macos/PLAN.md) for the
design and the page ↔ app bridge.

## How it works

Kindle Cloud Reader renders each page as an image, so there is no text layer to
read. The pipeline is three stages:

1. **capture** — drives a real browser through the book, saving one image per
   rendered page plus the table of contents and metadata.
2. **transcribe** — reads the text off each page image and stores it in
   `content.json`. On macOS this uses Apple's Vision framework locally;
   elsewhere, or with `--model`, an OpenAI vision model.
3. **export** — reassembles the text into markdown.

Re-running skips any stage whose output already exists, but how much of a
half-finished book survives depends on the stage. When the Kindle reader stops
turning pages mid-capture, the capture reloads it, returns to the last page it
saved and carries on, up to three times. A capture that still can't finish, or
whose run was interrupted, cannot be continued later: it is reported as
incomplete, and the book has to be captured again from the beginning with
`--force-capture` (the web app shows a **Capture again** button on such a book
instead). Transcription
resumes at page granularity — if some pages fail, re-running retries only
those, rather than paying to read the whole book again. Export is regenerated
from `content.json` whenever it is asked for, so it costs nothing to redo. Use
`--force-ocr` (or `--force`) to redo a stage deliberately.

Pages that could never be read are listed explicitly and the command exits
non-zero — an export with holes in it isn't success, even though a file was
written.

## Install

Requires Node 20+. Uses Google Chrome if installed, otherwise Playwright's
bundled Chromium. On macOS, the Xcode command line tools
(`xcode-select --install`) enable free local OCR; without them the build still
succeeds and transcription falls back to OpenAI.

```bash
git clone https://github.com/sjoblom/kindle-export
cd kindle-export
pnpm install
pnpm build
npm link          # optional: puts `kindle-export` on your PATH
```

Without `npm link`, run it as `pnpm kindle-export <args>`.

There is nothing you have to configure on macOS. `kindle-export setup` asks
where books should go and offers to sign in to Amazon; off macOS it also asks
for the OpenAI key that reading pages needs there. Both are stored in
`~/.kindle-export/config.json`:

```bash
kindle-export setup
```

(A key in `.env` or the environment also works and takes precedence; the web
app's Settings screen writes the same stored config.)

Sign in once. This opens a browser, lets you complete login and 2FA
yourself, and stores the session under `~/.kindle-export/profile`:

```bash
kindle-export login
```

**You do not need to put your Amazon password anywhere.** If the stored session
expires, a browser window opens and you sign in by hand. `AMAZON_EMAIL` and
`AMAZON_PASSWORD` exist only if you want sign-in scripted for unattended runs.

### What leaves your machine

On macOS, in the default configuration: **nothing**. Pages are read locally by
Apple's Vision framework, your Amazon session stays in a local browser profile,
and the text and images stay in `out/`. The only network traffic is with Amazon
itself, to read the book you already own.

Passing `--model` or setting `OCR_MODEL` (or running off macOS) sends every
page image to OpenAI to be transcribed instead. That costs roughly one
vision-model call per page — a few tens of cents for a 300-page book on
`gpt-4.1-mini`, the model used off macOS unless you name another.

### Platform support

Developed and tested on **macOS**, where it also reads pages locally. It uses
Google Chrome when installed and falls back to Playwright's bundled Chromium
otherwise, which should cover Linux and containers — but that fallback path is
**untested**, so treat Linux and Windows as unverified rather than supported.
Off macOS, transcription requires an OpenAI key. Set `BROWSER_CHANNEL` to pick
a specific channel (`chrome`, `msedge`, …) or leave it unset for the default.
Reports welcome.

## Usage

```
kindle-export serve                  open the web app in your browser
kindle-export                        pick books from your library, then export
kindle-export <ASIN...>              capture, transcribe and export
kindle-export login                  sign in once, storing the session
kindle-export list                   list the books in your Kindle library
kindle-export capture <ASIN...>      capture page images only
kindle-export ocr <ASIN...>          transcribe captured pages only
kindle-export export <ASIN...>       render markdown from transcribed text only
```

Useful options: `--format md,pdf`, `--json` and `--limit` for `list`,
`--port` for `serve`, plus `--out-dir`, `--profile-dir`, `--model`,
`--concurrency`, `--otp` and `--force`. Run `kindle-export --help` for the
full list.

`--model <name>` (or `OCR_MODEL` in the environment or `.env`) switches
transcription from local OCR to an OpenAI model, which needs an API key. It is
deliberately a per-run choice rather than a stored setting, so a Mac never
starts paying for what it can read for free; `kindle-export serve --model ...`
applies it to the web app too. Leave it unset on macOS.

`list` reads the same internal JSON endpoint the Kindle library page uses, so
it sees everything in your account and pages through it. Piping `--json`
elsewhere is the easy way to script a bulk export.

The ASIN is also in the Amazon URL for a book — `.../dp/B01H4G2J1U`.

## Output

```
out/<ASIN>/
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
