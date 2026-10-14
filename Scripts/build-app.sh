#!/usr/bin/env bash
# Build Culprit.app into build/ and print its path.
# --universal builds for arm64 and x86_64 (what releases ship); the default is this Mac only.
# Version comes from VERSION; the build number is the commit count, so it only goes up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHS=()
if [[ "${1:-}" == "--universal" ]]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release --product Culprit ${ARCHS[@]+"${ARCHS[@]}"} >&2
BINARY="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Culprit"

STAGE="$ROOT/build/Culprit.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/Culprit"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Culprit</string>
    <key>CFBundleDisplayName</key><string>Culprit</string>
    <key>CFBundleIdentifier</key><string>dev.aliir74.Culprit</string>
    <key>CFBundleExecutable</key><string>Culprit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$STAGE" >/dev/null 2>&1
echo "$STAGE"
