# kindle-export vs. Amazon's terms: a risk report

_Researched 2026-09-23. This is an informational analysis written by an AI
assistant from the code in this repo and publicly available terms, statutes and
reporting. It is **not legal advice**. The two questions that matter most (§52e
and §12 of the Swedish Copyright Act) are worth an hour with a Swedish IP lawyer
before the tool is promoted widely._

---

## TL;DR

- **Whether it breaks the terms is not really in doubt: it does, in several
  places.**
  - The core purpose (turn a licensed Kindle book into an unprotected
    Markdown/PDF file) breaches the Kindle Store Terms' licence scope and their
    anti-circumvention clause.
  - The way it does it breaches the newer **Agent Terms** in Amazon's
    Conditions of Use, and the no-reverse-engineering clause.
  - Neither breach can be fixed without the tool no longer working.
- **Risk to a user:** mainly contractual. The realistic worst case is that
  Amazon **closes the account and revokes the whole Kindle library without a
  refund**.
  - I found no documented case of Amazon banning a user for this. Enforcement
    has been technical (format changes, removing USB download) rather than
    against individuals.
  - Under Swedish law the user's own copying is shakier than in the US. §12 URL
    limits private copies of written works to "limited parts" of the work.
- **Risk to you as the developer:** mainly **anti-circumvention "trafficking"**
  law (US 17 U.S.C. §1201(a)(2)/(b); Swedish URL §52e). This applies to you
  whether or not you ever use the tool.
  - Realistic worst case: a DMCA notice to GitHub, or a cease-and-desist
    letter.
  - Tail risk: a lawsuit. Amazon sued Perplexity in 2025 over *concealed*
    automation, which is the category the anti-detection features in this repo
    fall into.
  - You are also an Amazon customer, so your own account carries the user risk
    too.
- **What makes it look worse than it needs to** (all fixable):
  - the anti-detection measures (spoofed Safari user agent, removed automation
    flag, blocked telemetry);
  - code comments that describe them as bypasses;
  - "bulk export" framing;
  - the product name *Kindle Export*.

---

## 1. What the app does that the analysis turns on

| # | Behaviour | Where |
|---|---|---|
| F1 | Drives Kindle Cloud Reader (`read.amazon.com`) automatically: opens a book, turns every page, saves each page image | `src/extract-kindle-book.ts` |
| F2 | Injects a script that **replaces `URL.createObjectURL`** to copy each decoded page image before the reader revokes it ("kindle's renderer revokes them immediately") | `src/extract-kindle-book.ts:224-256` |
| F3 | Launches Chrome with **`bypassCSP: true`** ("bypass amazon's default content security policy which allows us to inject our own scripts") | `src/extract-kindle-book.ts:216` |
| F4 | Removes Chrome's automation markers: ignores `--enable-automation` ("disable chrome's default automation detection flag") and `AutomationControlled` | `src/extract-kindle-book.ts:206-212` |
| F5 | Mac app: sets a **spoofed Safari user agent** on the WKWebView and on direct requests | `macos/Sources/KindleExportKit/Capture/ReaderSession.swift:37,101,609` |
| F6 | **Blocks Amazon telemetry/experiment hosts** (`unagi-*.amazon.com`, `remote-weblab-triggers`, `showads`) | `src/extract-kindle-book.ts:63-67` |
| F7 | Intercepts internal endpoints: `/renderer/render` (TAR bundles, saved to disk), `/service/mobile/reader/startReading`, `YJmetadata.jsonp`, and the library's internal JSON endpoint | `src/extract-kindle-book.ts:474-510`, `src/kindle-library.ts:15` |
| F8 | Runs **out of sight**: minimized Chrome window with background throttling disabled; in the Mac app, an offscreen window with occlusion detection turned off | `src/extract-kindle-book.ts:200-204`, `ReaderSession.swift:111,190` |
| F9 | Optional **scripted login** with `AMAZON_EMAIL` / `AMAZON_PASSWORD` / `AMAZON_OTP` | `src/extract-kindle-book.ts:660-715` |
| F10 | OCRs the pages (Apple Vision locally, or **uploads page images to OpenAI**) and writes **unprotected Markdown/PDF** | `src/transcribe-book-content.ts`, `src/openai-ocr.ts` |
| F11 | Library listing and "script a bulk export" (README) | `README.md`, `src/kindle-library.ts` |
| F12 | Distributed publicly (MIT, `github.com/sjoblom/kindle-export`), including a double-clickable **"Kindle Export.app"** aimed at non-technical users | `README.md`, `macos/` |

Things the app does **not** do, which help its position: it does not decrypt
Amazon's files offline, does not share or upload exports anywhere, does not
solve CAPTCHAs, does not add human-like random delays, and on macOS sends
nothing to third parties.

---

## 2. Which terms apply

| Document | Current version | Applies to |
|---|---|---|
| **Kindle Store Terms of Use** ([US](https://www.amazon.com/gp/help/customer/display.html?nodeId=201014950)) | Last updated **June 30, 2026** | Every Kindle book, and Kindle for Web (there are no separate Cloud Reader terms) |
| **Amazon.com Conditions of Use** ([US](https://www.amazon.com/gp/help/customer/display.html?nodeId=508088)) | Last updated **Aug 14, 2026** | All use of Amazon services, including the Agent Terms and Additional Software Terms |
| amazon.co.uk / .de Kindle Store Terms | 30 June 2026 | EU/UK stores (Amazon Media EU S.à r.l.) |
| amazon.se / .de / .co.uk Conditions of Use &amp; Sale | 8 Aug 2025 (SE), 28 Nov 2025 (DE/UK) | EU/UK; Luxembourg law plus mandatory consumer law of the buyer's country |

**Note for a Swedish user:** `amazon.se` has no Kindle store of its own; it
redirects to amazon.com's. A Swede buying Kindle books is therefore most likely
bound by the **US** Kindle Store Terms and US Conditions of Use. Those were
changed on Aug 14, 2026 to **binding JAMS arbitration** with a class waiver,
under Washington law. (The research agent could not confirm the redirect from a
Swedish IP address.)

At checkout every Kindle product page now says: *"By placing an order, you're
purchasing a content license &amp; agreeing to Kindle's Store Terms of Use."*
That is clickwrap-style assent, which courts generally enforce.

---

## 3. How a **user** of the app breaches the terms

Severity is my judgement of how clear the breach is and how much it matters.

| Clause (verbatim, current) | Triggered by | Severity |
|---|---|---|
| **Kindle Store Terms §1:** the licence is to view, use and display Kindle Content *"solely through Kindle Software or as otherwise permitted as part of the Service … solely for your personal, non-commercial use."* | F10: a Markdown/PDF file read outside Kindle Software is outside the licence. Personal, non-commercial use is satisfied; "solely through Kindle Software" is not. | **Clear breach**; it is the whole purpose of the app |
| **Kindle Store Terms, Limitations:** *"you may not attempt to bypass, modify, defeat, or otherwise circumvent any digital rights management system or other content protection or features used as part of the Service."* | F2, F3, F7. "Other content protection **or features**" is broad. Hooking the image pipeline to defeat blob revocation, and bypassing CSP, are hard to describe as anything else. | **Clear breach** |
| **Conditions of Use, Licence and Access:** the licence does not include *"any derivative use of any Amazon Service or its contents"* or *"any use of data mining, robots, or similar data gathering and extraction tools."* | F1, F7, F11 | **Clear breach** |
| **Conditions of Use, Agent Terms** (added May 2025): an "Agent" is *"any software or service that takes autonomous or semi-autonomous action on behalf of, or at the instruction of, any person."* Agents must **(i)** put `Agent/[agent name]` in the user-agent string; **(ii)** *"not conceal or obfuscate that any access … [is] from an Agent"*; **(iv)** not circumvent *"any measure intended to block, limit, modify, or control whether and how Agents access"* Amazon Services. | The app is plainly an Agent (F1). (i) is not met anywhere. (ii) is breached by F4, F5 and F8. F6 (blocking telemetry) is arguably (ii) or (iv). | **Clear breach**, and the one most tied to deliberate choices in this code |
| **Conditions of Use, Additional Software Terms / No Reverse Engineering:** you may not *"reverse engineer … tamper with, apply any other process or procedure to derive … underlying components …, or bypass any security associated with the Amazon Software."* (EU versions add "unless explicitly permitted under applicable mandatory law.") | F2, F3, F7: patching the reader's JavaScript at runtime, unpacking `/renderer/render` TARs, reading internal APIs | **Likely breach** |
| **Conditions of Use, Your Account:** you are *"responsible for maintaining the confidentiality of your account and password"* | F9, only if the user puts the password in `.env`. The default flow (the user signs in by hand in Amazon's own page) avoids this. | Minor / optional |
| **Kindle Store Terms, Limitations:** no sell, rent, distribute, sublicense … *"any portion of it to any third party"* | Only if the user shares an export. The app doesn't; the README says not to. | Not triggered by the app itself |

**Consequences Amazon has reserved:**

- **US terms:** *"Your rights under this Agreement will automatically terminate
  if you fail to comply with any term … Amazon may immediately revoke your
  access to the Service **without refund** of any fees."*
- Conditions of Use: Amazon may *"terminate accounts … in its sole
  discretion."*
- Kindle books are licences tied to the account, so account closure means
  losing **the entire library**, not just the exported books. The 2012 Linn
  Nygård case (a Norwegian amazon.co.uk customer whose account and library were
  locked without explanation, then restored after press coverage) shows this
  can happen.
- **EU/UK terms are softer:**
  - Termination only for a *"material"* failure.
  - Account closure needs advance notice (with exceptions), written reasons and
    a right of appeal.
  - These protections would apply to a Swede only if the Swede's Kindle
    contract is with the EU entity. See §2.

**Beyond contract**, what the user themselves risks under law (see §5 for
detail):

- **US:** the act of circumventing an *access* control is itself prohibited
  (§1201(a)(1)), and owning the book is no defense (*Universal v. Corley*).
  Whether capturing Amazon's own decoded output counts as "circumvention" is
  **unsettled**. No US exemption covers personal format-shifting of ebooks; the
  Copyright Office refused one in 2015. Practical risk to an individual is very
  low.
- **Sweden:**
  - **URL §52d** prohibits circumvention, but exempts someone with lawful
    access who circumvents *"för att kunna se eller lyssna på verket"* ("to be
    able to see or listen to the work"). Exporting a file is copying, not
    viewing, so the exemption probably doesn't reach it. That is untested. The
    penalty is a fine at most.
  - **URL §12** (private copying): *"Såvitt gäller litterära verk i skriftlig
    form får exemplarframställningen dock endast avse begränsade delar av
    verk"* ("for written literary works, the copying may only cover limited
    parts of the work"). **A full-book export is outside the private-copying
    exception on the statute's plain text**, regardless of DRM.
  - Ebooks are not "sold" in EU law (*Tom Kabinet*, C-263/18), so there is no
    ownership argument to fall back on.
- **OpenAI OCR path:** OpenAI's terms require that you *"have all rights,
  licenses, and permissions needed to provide Input."* Uploading pages whose
  licence says "solely through Kindle Software" arguably breaches that warranty.
  It is unlikely anyone would enforce it, and local OCR on macOS avoids the
  issue.

---

## 4. Your exposure as **developer and publisher**

The terms above bind you only as an Amazon customer. As the *author* of the
tool you are not a party to them for other users. Your exposure is different in
kind.

### 4.1 Anti-circumvention "trafficking": the main one

- **US, 17 U.S.C. §1201(a)(2) and (b):** bans offering to the public or
  "providing" a technology *primarily designed* to circumvent a technological
  measure, or marketed for that use.
  - Publishing on GitHub is providing.
  - Trafficking has **no personal-use or fair-use defense** (*321 Studios*).
  - The 2024 Copyright Office exemptions (accessibility for print-disabled
    readers; text and data mining for nonprofit university researchers) **never
    cover trafficking**.
  - Civil statutory damages are $200–$2,500 per act or device (§1203).
  - Criminal liability (§1204) requires wilfulness for commercial advantage or
    financial gain. A free MIT tool is far from that.
- **Sweden, URL §52e:**
  - Bans making, distributing or transmitting ("överföra") devices *"huvudsakligen
    … framtagna"* ("mainly … made") to circumvent, **with no commercial-purpose
    requirement** (unlike possession, which needs one).
  - Penalty under §57b: fines or **up to 6 months' imprisonment** for
    intentional or grossly negligent breach.
  - This is the provision that applies to you personally. The research found no
    case applying it to a free, open-source tool; that is a gap, not
    reassurance.
- **The unsettled question that decides all of this:** is Kindle for Web's
  rendering pipeline an "effective technological measure", and is capturing its
  output "circumvention"?
  - **In your favour:**
    - The app decrypts nothing; it copies bitmaps Amazon's own reader has
      already decoded inside a session the user is entitled to (the "analog
      hole").
    - In 2022 Amazon itself sent GitHub a notice claiming a screenshot block
      was a technological measure, and GitHub found *"not sufficient
      information to determine a valid anti-circumvention claim"*
      (`github/dmca` 2022-08-05).
  - **Against you:**
    - The app doesn't just screenshot. It patches `URL.createObjectURL`, bypasses
      CSP, and unpacks internal render TARs specifically to beat revocation.
    - A Feb 2026 N.D. Cal. decision (*Cordova v. Huneault*, reported by
      TorrentFreak) treated YouTube's JavaScript cipher as an access control even
      for free videos.
    - Kindle Web's obfuscation (token-gated renders, glyph substitution) was
      publicly reverse-engineered in Oct 2025, and that write-up describes it
      as DRM.
    - The code comments in F3 and F4 say "bypass" and "automation detection" in
      so many words. That is exactly the evidence a "primarily designed to
      circumvent" argument would cite.
- **EU angle:** InfoSoc Art. 6(4)'s mechanism for forcing access for private
  copying explicitly doesn't apply to on-demand services "on agreed contractual
  terms", which is exactly Kindle. Proportionality (*Nintendo v PC Box*,
  C-355/12) is a weak shield here.

### 4.2 Secondary liability for users' breaches and copies

- **Inducement (*MGM v. Grokster*)** needs promotion of infringing use. The
  README's Scope section (personal use only, don't redistribute, "contrary to
  Amazon's terms of service") cuts the other way and is worth keeping.
- **Inducing breach of contract / tortious interference** is the theory
  platforms use against bot and cheat makers:
  - *Blizzard v. Bossland*: $8.5M default judgment.
  - *Nintendo v. Tropic Haze (Yuzu)*: $2.4M settlement on §1201 claims.
  - Both were commercial sellers, which you are not.

### 4.3 Computer-access law (CFAA, Swedish dataintrång)

- ***Van Buren* (2021):** a terms-of-service breach alone isn't "exceeding
  authorized access".
- **Amazon v. Perplexity** (filed Nov 2025 over the Comet agent browser;
  preliminary injunction granted Mar 2026):
  - The research agent reports the **Ninth Circuit vacated the injunction on
    Aug 4, 2026**, holding that the *user* is the one accessing and the agent
    is a tool.
  - I verified this only through secondary reporting; confirm before relying on
    it.
  - If it holds, CFAA risk to a tool author is low. The case still shows
    **Amazon will litigate over disguised automation**.
- **Where risk rises:** under *Facebook v. Power Ventures*, continuing after a
  cease-and-desist or an IP block *is* a CFAA problem. If Amazon ever writes to
  you, don't ship workarounds to its blocks.
- **Sweden, BrB 4:9c dataintrång:** requires "olovligen" (unauthorised) access.
  Found no authority treating a logged-in user automating their own account as
  unauthorised. Low risk, but untested.

### 4.4 Trademark

- **"Kindle Export.app" and the repo name use Amazon's mark as the product
  name.** Referential use is allowed: US nominative fair use; in the EU, EUTMR
  Art. 14(1)(c), *Gillette* and *BMW v Deenik*.
- **Amazon's own developer branding guidelines** allow referring to Amazon
  products only with words like "for" or "to", with no Amazon logos, and with a
  disclaimer that the app was not created or endorsed by Amazon.
- The README already has the disclaimer. The name is the weak point; it's
  cheap to fix.

### 4.5 Platform takedown (the most likely event)

- **GitHub's DMCA policy:**
  - It reviews §1201 claims technically and legally.
  - It gives the owner a chance to change the code first.
  - It leaves content up when a claim is ambiguous.
  - Forks must each be named in the notice.
  - After youtube-dl (taken down Oct 2020, reinstated Nov 2020) GitHub set up a
    developer defense fund.
- **Precedents:**
  - Scribd v. `scribd-downloader` (2019, §1201 claim against a web-reader
    downloader, the closest analogue to this tool).
  - Readium/EDRLab v. DeDRM LCP code (2022, and again **2026-09-14**).
  - **No Amazon notice about any Kindle tool** in `github/dmca` (about 60 Amazon
    notices, 2013–2026, checked).
  - The upstream `kindle-ai-export` is still live.
  - `PixelMelt/amazon_book_downloader` (a Kindle Web DRM tool, Oct 2025) now
    returns 404, **reason unknown**. There is no public DMCA notice for it.
- **Mac app distribution:** it is ad-hoc signed and not notarised, so Apple's
  developer terms aren't engaged. Submitting it to the Mac App Store would be
  rejected on IP grounds and would put you under Apple's agreement. Don't.

### 4.6 Your own Amazon account

You develop and test against your own account, so everything in §3 applies to
you. The account also contains the books the app is for. The developer is also
the most identifiable user if Amazon ever connects a GitHub repo to an account.

---

## 5. How Amazon actually enforces

- **Against users:** no verified case of an account closed for using an
  export or DRM-removal tool. There are only anecdotes and speculation,
  including upstream issue #18 about telemetry-based bans.
- **Account-level actions that are documented:**
  - Linn Nygård, 2012: closure for an unrelated "abuse" link.
  - Orwell remote deletion, 2009, then the *Gawronski* settlement promising not
    to remotely delete content except in listed cases.
- **Technical tightening is the main pattern:**
  - "Download &amp; Transfer via USB" removed **Feb 26, 2025**.
  - KFX-ZIP delivery that breaks DeDRM (Mar 2026).
  - Forced desktop app updates.
  - The Agent Terms (May 2025).
  - Expect Kindle for Web to become harder to automate too. The telemetry this
    app blocks (F6) is one plausible detection channel.
- **Against tool authors:**
  - A DMCA notice to MobileRead over `kindlepid.py` (2009).
  - The Perplexity lawsuit (2025–26), targeting concealed agents.
  - Nothing against DeDRM's Kindle code, Epubor-type commercial tools, or
    kindle-ai-export that the research could find.

---

## 6. Risk matrix

| Risk | Who | Likelihood | Impact |
|---|---|---|---|
| Account closure plus loss of the whole Kindle library | User (and you) | Low | **High**; US terms: no refund |
| Books rendered unusable by a Kindle Web change (tool stops working) | User | **High** over time | Low; exports already made remain |
| DMCA §1201 notice to GitHub | You | Low–moderate; rises with visibility | Moderate; repo disabled, fixable or counter-noticeable |
| Cease-and-desist from Amazon | You | Low | Moderate; must stop or litigate |
| Civil suit (§1201 trafficking / contract) | You | Very low for a free non-commercial tool | High |
| Swedish §52e prosecution | You | Very low (no known precedent for free OSS) | High |
| Copyright claim over a user's own personal copy | User | Very low | Low–moderate |
| Copyright claim over **shared** exports | Whoever shares | Moderate if discovered | High; clearly infringing |
| Trademark complaint over "Kindle Export" | You | Low | Low; rename |

---

## 7. What would reduce the risk

None of these makes the app *compliant*. Its purpose is incompatible with
"solely through Kindle Software", so the Kindle Store Terms can't be satisfied.
These changes move it away from what enforcement targets.

**Worth doing now (cheap, and they reduce the developer risk most):**

1. **Rename the product** so "Kindle" is referential: e.g. "Book Export *for*
   Kindle" or a neutral name. Keep the non-affiliation disclaimer.
2. **Rewrite code comments** that narrate intent ("bypass amazon's … content
   security policy", "disable chrome's default automation detection flag") to
   describe *function* neutrally. Don't remove the behaviour just to hide it;
   the aim is not to supply ready-made "primarily designed to circumvent"
   quotes.
3. **Drop "script a bulk export" marketing** from the README. Keep the Scope
   section and its "don't redistribute" line prominent, near the top.
4. **Remove scripted password login** (F9), or at least stop documenting it.
   It is the only path where the app handles credentials, and "unattended runs"
   reads like a service, not personal use.

**Worth considering (these trade reliability for a better story):**

5. **Stop disguising the agent** (F4, F5, F6): leave Chrome's automation flag
   on, don't spoof Safari, don't block telemetry. This addresses the clearest
   and most deliberate breach (the Agent Terms (ii)). The honest cost: Amazon
   may then detect and block it more easily. Adding `Agent/kindle-export` to
   the user agent would meet (i) literally, but Amazon can then ask the agent to
   stop, and it would have to.
6. **Make local OCR the only path**, or warn clearly before sending pages to
   OpenAI. This removes the third-party upload and the OpenAI warranty issue.
7. **Keep it low-profile and non-commercial:** no donations, paid builds or
   hosted version. Commerciality is what turns §1204 and most of the tool-maker
   precedents on.

**If contacted:**

8. If Amazon or GitHub sends a notice, **don't ship a workaround to a block**
   (the *Power Ventures* line). Get a lawyer before counter-noticing. EFF and
   the GitHub Developer Defense Fund have backed tool authors in §1201 cases.

---

## 8. Open questions and unverified points

- **Unsettled:** whether capturing Kindle for Web's decoded images is
  "circumvention" under §1201 or URL §52d/§52e. There is no case on point.
  *Yout v. RIAA* (2d Cir.) is pending on a similar question.
- **Unsettled:** whether a Swede's full-book personal copy can ever fit URL §12.
  The text says "begränsade delar" (limited parts).
- **Verified only secondhand:**
  - Ninth Circuit ruling in *Amazon v. Perplexity* (Aug 4, 2026).
  - *Cordova v. Huneault* (N.D. Cal., Feb 2026).
  - The KFX-ZIP change (Mar 2026).
- **Not confirmed:** that Swedish buyers contract with Amazon.com Services LLC
  under US terms (the redirect was observed from a non-Swedish IP).
- **Not confirmed:** why `PixelMelt/amazon_book_downloader` disappeared.
- The research did not find any clause banning credential sharing with
  third-party tools specifically.

---

## Sources

**Amazon:**

- Kindle Store Terms of Use (US):
  https://www.amazon.com/gp/help/customer/display.html?nodeId=201014950
- Conditions of Use (US), including Agent Terms and Disputes:
  https://www.amazon.com/gp/help/customer/display.html?nodeId=508088
- Conditions of Use &amp; Sale:
  - amazon.se:
    https://www.amazon.se/gp/help/customer/display.html?nodeId=GLSBYFE9MGKKQXXM
  - amazon.de:
    https://www.amazon.de/gp/help/customer/display.html?nodeId=201909000
  - amazon.co.uk:
    https://www.amazon.co.uk/gp/help/customer/display.html?nodeId=1040616
- Kindle for Web help:
  https://www.amazon.com/gp/help/customer/display.html?nodeId=GCQEMKHLBENNKWU2
- Amazon trademark guidelines for app developers:
  https://developer.amazon.com/support/legal/tuabg

**Statutes:**

- 17 U.S.C. §1201: https://www.law.cornell.edu/uscode/text/17/1201
- 2024 §1201 exemptions:
  https://www.federalregister.gov/documents/2024/10/28/2024-24563/exemption-to-prohibition-on-circumvention-of-copyright-protection-systems-for-access-control
- InfoSoc Directive 2001/29/EC:
  https://eur-lex.europa.eu/LexUriServ/LexUriServ.do?uri=CELEX:32001L0029:EN:HTML
- Upphovsrättslagen (1960:729):
  https://www.riksdagen.se/sv/dokument-och-lagar/dokument/svensk-forfattningssamling/lag-1960729-om-upphovsratt-till-litterara-och_sfs-1960-729/
- Dataintrång, BrB 4:9c: https://lagen.nu/begrepp/Dataintr%C3%A5ng

**Cases:**

- *Van Buren v. United States*:
  https://www.supremecourt.gov/opinions/20pdf/19-783_k53l.pdf
- *MDY v. Blizzard*:
  https://cdn.ca9.uscourts.gov/datastore/opinions/2011/02/17/09-15932.pdf
- *Green v. DOJ*: https://www.eff.org/cases/green-v-us-department-justice
- *Tom Kabinet*:
  https://ipkitten.blogspot.com/2019/12/breaking-cjeu-rules-that-provision-of.html
- *Nintendo v PC Box*:
  https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A62012CJ0355
- *hiQ v. LinkedIn* contract outcome:
  https://www.privacyworld.blog/2022/11/federal-court-rules-in-favor-of-linkedins-breach-of-contract-claim-after-six-years-of-cfaa-data-scraping-litigation/
- *Meta v. Bright Data*:
  https://newmedialaw.proskauer.com/2024/01/24/california-court-issues-noteworthy-decision-on-breach-of-contract-claims-in-web-scraping-dispute/
- *Amazon v. Perplexity* (9th Cir.):
  https://peopleofinternet.com/articles/in-amazon-v-perplexity-the-ninth-circuit-puts-cfaa-liability.html
- *Cordova v. Huneault*:
  https://torrentfreak.com/ripping-clips-for-youtube-reaction-videos-can-violate-the-dmca-court-rules/
- *Blizzard v. Bossland*:
  https://torrentfreak.com/blizzard-beats-cheat-maker-wins-85-million-copyright-damages-170403/
- *Nintendo v. Tropic Haze*:
  https://www.engadget.com/makers-of-switch-emulator-yuzu-quickly-settle-with-nintendo-for-24-million-203204698.html

**GitHub:**

- DMCA takedown policy:
  https://docs.github.com/en/site-policy/content-removal-policies/dmca-takedown-policy
- youtube-dl reinstatement:
  https://github.blog/news-insights/policy-news-and-insights/standing-up-for-developers-youtube-dl-is-back/
- The notices themselves are in `github.com/github/dmca`.

**OpenAI:**

- Terms of Use: https://openai.com/policies/row-terms-of-use/
- Services Agreement: https://cdn.openai.com/osa/openai-services-agreement.pdf

**Kindle Web DRM analysis:** https://blog.pixelmelt.dev/kindle-web-drm/

**USB download removal:**
https://blog.the-ebook-reader.com/2025/02/13/psa-download-your-kindle-ebooks-now-before-amazon-removes-the-option/
