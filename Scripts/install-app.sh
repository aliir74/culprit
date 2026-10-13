#!/usr/bin/env bash
# Build Culprit.app and install it into /Applications (or the directory given).
# Works from any directory: it builds from the repo root, not from where it was called.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-/Applications}"
APP_NAME="Culprit.app"
STAGE="$ROOT/build/$APP_NAME"

cd "$ROOT"
swift build -c release --product Culprit
BINARY="$ROOT/.build/release/Culprit"

rm -rf "$ROOT/build/$APP_NAME"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/Culprit"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Culprit</string>
    <key>CFBundleDisplayName</key><string>Culprit</string>
    <key>CFBundleIdentifier</key><string>dev.aliir74.Culprit</string>
    <key>CFBundleExecutable</key><string>Culprit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$STAGE" >/dev/null

# Staged and moved, never overwritten in place: overwriting a signed bundle leaves the
# kernel holding a stale signature and later launches get killed.
INCOMING="$DESTINATION/.Culprit.app.incoming"
rm -rf "$INCOMING"
ditto "$STAGE" "$INCOMING"
rm -rf "$DESTINATION/$APP_NAME"
mv "$INCOMING" "$DESTINATION/$APP_NAME"
echo "installed $DESTINATION/$APP_NAME"
