#!/bin/bash
# Builds Paper.app — a self-contained macOS app bundle, ad-hoc signed.
# Needs the Command Line Tools; nothing else. No package manager, no dependencies.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/Paper.app"
CONFIG="${1:-release}"
# Reverse-DNS id for the bundle. Override it to use your own: PAPER_BUNDLE_ID=com.yourname.paper ./build.sh
BUNDLE_ID="${PAPER_BUNDLE_ID:-com.example.paper}"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --arch arm64

BIN="$ROOT/.build/$CONFIG/Paper"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN"; exit 1; }

# The self-test carries the schema gate, which is the thing standing between a
# routine field addition and every ledger on disk becoming unreadable. A gate
# that only runs when someone remembers to run it is not a gate, so the build
# does not produce a bundle that fails it.
#
# PAPER_DATA_DIR points the run at a throwaway directory. The tests build their
# own temporary ledgers, but the logger writes beside the data, and a build step
# has no business touching the accounts someone actually keeps.
if [ "${SKIP_TESTS:-}" = "1" ]; then
  echo "==> Self-test SKIPPED (SKIP_TESTS=1)"
else
  echo "==> Self-test"
  TESTDIR="$(mktemp -d)"
  trap 'rm -rf "$TESTDIR"' EXIT
  if ! PAPER_DATA_DIR="$TESTDIR" "$BIN" --selftest 2>&1 | tail -20; then
    echo
    echo "The self-test failed. No bundle was built."
    echo "Run it directly to see everything:  PAPER_DATA_DIR=\$(mktemp -d) $BIN --selftest"
    exit 1
  fi
fi

echo "==> Generating icon"
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --iconset "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Paper"
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The interface ships inside the bundle, so a built app does not depend on the
# source tree still being where it was built.
cp -R "$ROOT/site" "$APP/Contents/Resources/site"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Paper</string>
    <key>CFBundleDisplayName</key>        <string>Paper</string>
    <key>CFBundleExecutable</key>         <string>Paper</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>   <string>Simulation only. No real orders, no brokerage, no real money.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature ok"

echo
echo "Built $APP"
echo "Run it with:  open '$APP'"
