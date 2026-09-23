import Foundation

/// Everything `ReaderSession` runs inside the Kindle reader, in one place so
/// the tests can at least compile each piece.
///
/// Two worlds:
/// - the **page** world gets the hooks (`hooks`), because they must replace
///   the page's own `URL.createObjectURL`, `fetch` and `XMLHttpRequest`;
/// - an isolated **client** world gets the query helpers (`helpers`, exposed
///   as `__kx`) and every function body below, so nothing the page does can
///   break them and they don't show up on the page's globals.
///
/// Bodies are run with `callAsyncJavaScript`: they are async function bodies
/// whose named arguments are passed as values (no string splicing), and each
/// returns a JSON string (or null) that Swift decodes.
enum ReaderScripts {
  /// Message handler names (page → Swift).
  static let blobHandler = "kxBlob"
  static let netHandler = "kxNet"

  /// Installed at document start in the page world.
  ///
  /// - Every image blob turned into an object URL is copied out as a data
  ///   URL: Kindle's renderer revokes them right after use, so the bytes have
  ///   to be snapshotted immediately (extract-kindle-book.ts does the same
  ///   with an init script). Non-images can never be the page image.
  /// - `/renderer/render` (TAR), `startReading` (JSON) and `YJmetadata.jsonp`
  ///   responses are copied out whether they arrive by `fetch` or XHR —
  ///   Playwright's `page.on('response')` saw them regardless of transport;
  ///   here each transport has to be hooked.
  /// - `YJmetadata.jsonp` may instead be loaded by a `<script>` tag, which no
  ///   hook sees; its callback (`loadMetadata`) is wrapped for that case.
  static let hooks = #"""
    (() => {
      if (window.__kxHooked) return;
      window.__kxHooked = true;

      const post = (name, body) => {
        try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {}
      };
      const toDataURL = (blob) => new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      });

      const originalCreateObjectURL = URL.createObjectURL.bind(URL);
      URL.createObjectURL = function (object) {
        const url = originalCreateObjectURL(object);
        try {
          const type = (object && object.type) || '';
          if (object instanceof Blob && type.startsWith('image/')) {
            toDataURL(object)
              .then((data) => post('kxBlob', { url, type, data }))
              .catch(() => {});
          }
        } catch (e) {}
        return url;
      };

      const WANTED = /\/renderer\/render|\/service\/mobile\/reader\/startReading|YJmetadata\.jsonp/;
      const report = (url, status, blob) => {
        toDataURL(blob)
          .then((data) => post('kxNet', { url: String(url), status, data }))
          .catch(() => {});
      };

      const originalFetch = window.fetch;
      window.fetch = async function (...args) {
        const response = await originalFetch.apply(this, args);
        try {
          const input = args[0];
          const url = response.url || (input && input.url) || String(input);
          if (WANTED.test(url)) {
            response.clone().blob().then((b) => report(url, response.status, b)).catch(() => {});
          }
        } catch (e) {}
        return response;
      };

      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__kxUrl = url;
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        try {
          const requested = String(this.__kxUrl || '');
          if (WANTED.test(requested)) {
            this.addEventListener('load', () => {
              try {
                const url = this.responseURL || requested;
                let blob;
                switch (this.responseType) {
                  case '':
                  case 'text': blob = new Blob([this.responseText]); break;
                  case 'arraybuffer': blob = new Blob([this.response]); break;
                  case 'blob': blob = this.response; break;
                  case 'json': blob = new Blob([JSON.stringify(this.response)]); break;
                  default: return;
                }
                if (blob) report(url, this.status, blob);
              } catch (e) {}
            });
          }
        } catch (e) {}
        return originalSend.apply(this, arguments);
      };

      let loadMetadata;
      try {
        Object.defineProperty(window, 'loadMetadata', {
          configurable: true,
          get() { return loadMetadata; },
          set(fn) {
            loadMetadata = typeof fn !== 'function' ? fn : function (payload) {
              try {
                const text = 'loadMetadata(' + JSON.stringify(payload) + ');';
                report('jsonp:YJmetadata.jsonp', 200, new Blob([text]));
              } catch (e) {}
              return fn.apply(this, arguments);
            };
          },
        });
      } catch (e) {}
    })();
    """#

  /// Installed at document start in the client world: `globalThis.__kx`.
  ///
  /// `find(spec)` is a small stand-in for a Playwright locator:
  /// `{selector, text?, flags?, within?, deepest?, visible?}` — the first
  /// element matching `selector` (searching open shadow roots when the light
  /// DOM has none) whose text matches the regex `text`, optionally inside an
  /// element matching `within` (another spec), and visible unless
  /// `visible: false`. `deepest` picks the innermost matching descendant, for
  /// "the option labelled X inside this group".
  static let helpers = #"""
    (() => {
      const kx = {};

      kx.all = (selector, root) => {
        root = root || document;
        const light = Array.from(root.querySelectorAll(selector));
        if (light.length > 0) return light;
        const found = [];
        const visit = (node) => {
          for (const el of node.querySelectorAll('*')) {
            if (el.shadowRoot) {
              found.push(...el.shadowRoot.querySelectorAll(selector));
              visit(el.shadowRoot);
            }
          }
        };
        visit(root);
        return found;
      };

      kx.visible = (el) => {
        if (!el || !el.isConnected) return false;
        const rect = el.getBoundingClientRect();
        if (!(rect.width > 0 && rect.height > 0)) return false;
        const style = getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none';
      };

      kx.text = (el) => (el && el.textContent) || '';

      kx.find = (spec, root) => {
        const roots = spec.within
          ? [].concat(spec.within).flatMap((w) => kx.findAll(w, root))
          : [root || document];
        const re = spec.text != null ? new RegExp(spec.text, spec.flags || '') : null;
        for (const r of roots) {
          for (const el of kx.all(spec.selector, r)) {
            if (re && !re.test(kx.text(el))) continue;
            if (spec.visible !== false && !kx.visible(el)) continue;
            if (spec.deepest && re) {
              let inner = el;
              for (const child of el.querySelectorAll('*')) {
                if (re.test(kx.text(child)) && (spec.visible === false || kx.visible(child))) inner = child;
              }
              return inner;
            }
            return el;
          }
        }
        return null;
      };

      kx.findAll = (spec, root) => {
        const re = spec.text != null ? new RegExp(spec.text, spec.flags || '') : null;
        return kx.all(spec.selector, root).filter((el) =>
          (!re || re.test(kx.text(el))) && (spec.visible === false || kx.visible(el)));
      };

      kx.center = (el) => {
        const rect = el.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const hit = document.elementFromPoint(x, y);
        return { x, y, width: rect.width, height: rect.height, hit: !!hit && (hit === el || el.contains(hit) || (hit.getRootNode && hit.getRootNode().host === el)) };
      };

      globalThis.__kx = kx;
    })();
    """#

  // MARK: - function bodies (client world)

  /// Args: `spec`. The element's centre in CSS px, or null.
  static let elementCenter = #"""
    const el = __kx.find(spec);
    if (!el) return null;
    if (el.scrollIntoViewIfNeeded) el.scrollIntoViewIfNeeded(); else el.scrollIntoView({ block: 'nearest' });
    return JSON.stringify(__kx.center(el));
    """#

  /// Args: `spec`. Whether a (visible, unless the spec says otherwise) match exists.
  static let exists = #"""
    return JSON.stringify(!!__kx.find(spec));
    """#

  /// Args: `selector`. The first match's `src` attribute (light DOM fast path).
  static let imageSource = #"""
    const el = document.querySelector(selector) || __kx.all(selector)[0];
    return JSON.stringify(el ? el.getAttribute('src') : null);
    """#

  /// Args: `selector`. The first match's textContent, null when absent.
  static let textContent = #"""
    const el = document.querySelector(selector) || __kx.all(selector)[0];
    return JSON.stringify(el ? el.textContent : null);
    """#

  /// Args: `selector`. How many elements match.
  static let count = #"""
    return JSON.stringify(__kx.all(selector).length);
    """#

  /// Args: `selector`. extractBook's `hasUsableNextPageChevron`: present,
  /// visible and not disabled. Errors count as usable (the Swift side treats
  /// a failed evaluation the same way).
  static let usableChevron = #"""
    try {
      const el = __kx.all(selector)[0];
      if (!el) return JSON.stringify(false);
      if (!__kx.visible(el)) return JSON.stringify(false);
      const disabled =
        el.hasAttribute('disabled') ||
        el.getAttribute('aria-disabled') === 'true' ||
        el.classList.contains('disabled') ||
        !!el.querySelector('[disabled], [aria-disabled="true"], .disabled');
      return JSON.stringify(!disabled);
    } catch (e) {
      return JSON.stringify(true);
    }
    """#

  /// No args. `ensureFixedHeaderUI`: pin the reader's top chrome in place so
  /// the header (and its menu buttons) never slides away.
  static let fixHeader = #"""
    const el = document.querySelector('.top-chrome');
    if (!el) return JSON.stringify(false);
    el.style.transition = 'none';
    el.style.transform = 'none';
    return JSON.stringify(true);
    """#

  /// No args. Where to click to answer an alert in the way: the "No" of the
  /// "Most Recent Page Read" dialog, else the "No" of any other ion-alert
  /// (`dismissPossibleAlert`). `{x, y, kind}` or null.
  static let alertNoButton = #"""
    const dialogs = __kx.all('ion-alert, [role="dialog"], .alert-wrapper')
      .filter((d) => __kx.visible(d) && /most recent page read/i.test(__kx.text(d)));
    for (const dialog of dialogs) {
      const no = __kx.find({ selector: 'button, ion-button', text: '^\\s*no\\s*$', flags: 'i' }, dialog);
      if (no) return JSON.stringify(Object.assign(__kx.center(no), { kind: 'most-recent-page-read' }));
    }
    const other = __kx.find({ selector: 'ion-alert button', text: 'no', flags: 'i' });
    if (other) return JSON.stringify(Object.assign(__kx.center(other), { kind: 'alert' }));
    return null;
    """#

  /// Args: `spec`. Focus the matched input and select its contents, so typed
  /// characters replace them (Playwright's `fill` clears first).
  static let focusAndSelect = #"""
    const el = __kx.find(spec);
    if (!el) return JSON.stringify(false);
    el.focus();
    if (el.select) el.select();
    return JSON.stringify(true);
    """#

  /// Args: `spec`. The matched input's value, or null.
  static let inputValue = #"""
    const el = __kx.find(spec);
    return JSON.stringify(el ? String(el.value) : null);
    """#

  /// Args: `spec`, `value`. Fallback when typing didn't land: set the value
  /// through the native setter and fire `input`/`change`, which is what the
  /// reader's input component listens to.
  static let setInputValue = #"""
    const el = __kx.find(spec);
    if (!el) return JSON.stringify(false);
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return JSON.stringify(true);
    """#

  /// No args. Blur a focused text field so arrow keys turn pages instead of
  /// moving a caret.
  static let blurTextField = #"""
    const el = document.activeElement;
    if (el && /^(INPUT|TEXTAREA)$/.test(el.tagName)) { el.blur(); return JSON.stringify(true); }
    return JSON.stringify(false);
    """#

  /// No args. Resource URLs the page has loaded matching YJmetadata, for the
  /// fallback fetch when the hooks saw nothing.
  static let yjMetadataResources = #"""
    return JSON.stringify(performance.getEntriesByType('resource')
      .map((e) => e.name).filter((n) => /YJmetadata\.jsonp/.test(n)));
    """#

  /// Every body with its argument names, for the syntax check in the tests.
  static let bodies: [(name: String, arguments: [String], body: String)] = [
    ("elementCenter", ["spec"], elementCenter),
    ("exists", ["spec"], exists),
    ("imageSource", ["selector"], imageSource),
    ("textContent", ["selector"], textContent),
    ("count", ["selector"], count),
    ("usableChevron", ["selector"], usableChevron),
    ("fixHeader", [], fixHeader),
    ("alertNoButton", [], alertNoButton),
    ("focusAndSelect", ["spec"], focusAndSelect),
    ("inputValue", ["spec"], inputValue),
    ("setInputValue", ["spec", "value"], setInputValue),
    ("blurTextField", [], blurTextField),
    ("yjMetadataResources", [], yjMetadataResources),
  ]
}

/// A Playwright-locator-like element description, passed to `__kx.find`.
public struct ElementSpec: Codable, Equatable, Sendable {
  public var selector: String
  /// A regular expression (JS syntax) the element's textContent must match.
  public var text: String?
  public var flags: String?
  /// Only look inside elements matching this.
  public var within: [ElementSpec]?
  /// Pick the innermost descendant whose text matches.
  public var deepest: Bool?
  /// `false` to accept invisible elements (Playwright's `force`-less count).
  public var visible: Bool?

  public init(
    _ selector: String, text: String? = nil, flags: String? = nil,
    within: ElementSpec? = nil, deepest: Bool? = nil, visible: Bool? = nil
  ) {
    self.selector = selector
    self.text = text
    self.flags = flags
    self.within = within.map { [$0] }
    self.deepest = deepest
    self.visible = visible
  }

  /// Playwright's `hasText: 'string'`: a case-insensitive substring.
  public static func hasText(_ selector: String, _ substring: String) -> ElementSpec {
    ElementSpec(selector, text: NSRegularExpression.escapedPattern(for: substring), flags: "i")
  }
}
