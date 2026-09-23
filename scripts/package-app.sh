#!/bin/bash
# Build "Kindle Export.app" — the native Mac app (macos/, see macos/PLAN.md).
#
#   pnpm package                 # for this Mac's architecture
#   ARCH=universal pnpm package  # arm64 + x86_64 in one binary
#
# Node is needed here, at build time only: it bundles the shared TypeScript
# logic into kindle-core.js (run by JavaScriptCore inside the app) and renders
# the UI page into app.html. What ships is two Swift binaries — the app and
# its command-line tool, `kindle-export` — plus those two files and an icon:
# no Node, no node_modules, no Chrome, no OCR worker (Vision is called
# directly).
#
# The tool goes in Contents/MacOS next to the app's own executable, not in
# Contents/Helpers: only there does it run with the app's bundle identifier,
# and WebKit keys the Amazon session (WKWebsiteDataStore.default()) on that
# identifier — so the terminal shares the app's sign-in. See
# macos/Sources/KindleExportCLI/main.swift.
#
# The result is ad-hoc signed, not notarised. Installing it on someone else's
# Mac means copying it to /Applications and right-click → Open once; after
# that it opens like any other app.
set -euo pipefail

ARCH="${ARCH:-$(uname -m)}"
APP_NAME="Kindle Export"
PRODUCT="KindleExport"
CLI_PRODUCT="kindle-export"
DIST="dist-app"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "package-app: macOS only." >&2
  exit 1
fi

case "$ARCH" in
  arm64 | x86_64) SWIFT_ARCH_FLAGS=(--arch "$ARCH") ;;
  # Two --arch flags make SwiftPM build through Xcode's build system, which
  # needs a full Xcode rather than just the command line tools.
  universal) SWIFT_ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
  *) echo "package-app: unsupported ARCH '$ARCH' (arm64, x86_64 or universal)" >&2; exit 1 ;;
esac

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }

# `kindle-export --version` outside a bundle prints a compiled-in version;
# inside one it prints Info.plist's, written below from package.json. Both
# must say the same thing.
VERSION="$(node -p 'require("./package.json").version')"
CLI_VERSION="$(sed -n 's/^ *public static let version = "\(.*\)"$/\1/p' \
  macos/Sources/KindleExportKit/CLI/CommandLineOptions.swift)"
if [ "$CLI_VERSION" != "$VERSION" ]; then
  echo "package-app: package.json says $VERSION but CommandLineOptions.version says" \
    "'$CLI_VERSION' — update macos/Sources/KindleExportKit/CLI/CommandLineOptions.swift." >&2
  exit 1
fi

say "Bundling the shared logic and the page"
pnpm run build:core
pnpm run build:app-page

say "Compiling the app and the command-line tool ($ARCH)"
SWIFT_BUILD=(swift build -c release --package-path macos "${SWIFT_ARCH_FLAGS[@]}")
"${SWIFT_BUILD[@]}" --product "$PRODUCT"
"${SWIFT_BUILD[@]}" --product "$CLI_PRODUCT"
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
BINARY="$BIN_DIR/$PRODUCT"
CLI_BINARY="$BIN_DIR/$CLI_PRODUCT"
for built in "$BINARY" "$CLI_BINARY"; do
  if [ ! -x "$built" ]; then
    echo "package-app: $built was not built." >&2
    exit 1
  fi
done

rm -rf "$DIST"
mkdir -p "$CONTENTS/MacOS" "$RES"

# The binary is renamed to the bundle's display name so Activity Monitor and
# the Force Quit list show "Kindle Export", not the SwiftPM product name.
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
cp "$CLI_BINARY" "$CONTENTS/MacOS/$CLI_PRODUCT"
cp dist-core/kindle-core.js dist-core/app.html "$RES/"

say "Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.kindle-export.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

say "Drawing an icon"
# Nice to have, not worth failing the build over.
if ! sh scripts/make-icon.sh "$RES/icon.icns" 2>/dev/null; then
  echo "  (skipped — the app will use the generic icon)"
fi

# Ad-hoc signing keeps macOS from killing the bundle outright on Apple Silicon;
# it is not notarisation, so first launch still needs right-click → Open.
say "Signing ad-hoc"
# The tool first, as code of its own; then the bundle, whose seal covers it.
codesign --force --sign - "$CONTENTS/MacOS/$CLI_PRODUCT"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

say "Smoke-testing the bundle"
EXE="$CONTENTS/MacOS/$APP_NAME"
fail() { echo "package-app: $1" >&2; exit 1; }

CLI="$CONTENTS/MacOS/$CLI_PRODUCT"
[ -x "$EXE" ] || fail "the executable is missing"
[ -x "$CLI" ] || fail "the command-line tool is missing"
echo "  executable      $(lipo -archs "$EXE")"
echo "  kindle-export   $(lipo -archs "$CLI")"
for file in kindle-core.js app.html; do
  [ -s "$RES/$file" ] || fail "Resources/$file is missing"
done
echo "  resources       $(cd "$RES" && ls | tr '\n' ' ')"

# The whole point of the native app: it links nothing but what every Mac has.
# Anything outside /System and /usr/lib would be a library the bundle does not
# carry, and the app would crash on launch on another machine.
# Library lines are the indented ones; the others name the file (and, in a
# universal binary, each architecture slice).
FOREIGN="$(otool -L "$EXE" "$CLI" | grep -E '^[[:space:]]' | awk '{print $1}' \
  | grep -vE '^(/System/Library/|/usr/lib/)' || true)"
[ -z "$FOREIGN" ] || fail "links non-system libraries:
$FOREIGN"
echo "  links           system frameworks only"

# The tool answers without a window, from inside the bundle and through a
# link, as `kindle-export` on the PATH runs it. Its version must be the app's.
[ "$("$CLI" --version)" = "$VERSION" ] || fail "kindle-export --version is not $VERSION"
"$CLI" --help | grep -q '^Usage' || fail "kindle-export --help printed no usage"
LINK_DIR="$(mktemp -d)"
ln -s "$PWD/$CLI" "$LINK_DIR/kindle-export"
# Through the link it must still run as the app (it re-executes itself from
# the real path), or it would get a signed-out session of its own.
KINDLE_EXPORT_DEBUG=1 "$LINK_DIR/kindle-export" --version 2>&1 >/dev/null \
  | grep -q 'bundle com.kindle-export.app' \
  || fail "kindle-export through a symlink does not run as the app's bundle"
rm -rf "$LINK_DIR"
echo "  kindle-export   --version $VERSION, --help ok, runs as the app through a link"

# Leftovers from the Node-based app must never creep back in.
LEFTOVER="$(find "$APP" \( -name node -o -name node_modules -o -name 'kindle-ocr-macos' \) -print)"
[ -z "$LEFTOVER" ] || fail "bundle contains Node-era files:
$LEFTOVER"

SIZE="$(du -sh "$APP" | cut -f1)"
say "Built $APP ($SIZE)"
echo
echo "To install on another Mac (macOS 13 or later):"
echo "  1. Copy \"$APP_NAME.app\" to that Mac's /Applications folder"
echo "  2. Right-click it → Open → Open (once, because it isn't notarised)"
echo "  3. After that it opens with a normal double-click"
echo
echo "Nothing else to install. Books are written to"
echo "  ~/Documents/Kindle Export"
echo
echo "For Terminal: Kindle Export › Install Command-Line Tool… adds kindle-export."
echo "Or run it straight from the bundle:"
echo "  \"$CLI\" --help"
