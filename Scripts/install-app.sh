#!/usr/bin/env bash
# Build Culprit.app and install it into /Applications (or the directory given).
# Works from any directory: it builds from the repo root, not from where it was called.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-/Applications}"
STAGE="$("$ROOT/Scripts/build-app.sh")"

# Staged and moved, never overwritten in place: overwriting a signed bundle leaves the
# kernel holding a stale signature and later launches get killed.
INCOMING="$DESTINATION/.Culprit.app.incoming"
rm -rf "$INCOMING"
ditto "$STAGE" "$INCOMING"
rm -rf "$DESTINATION/Culprit.app"
mv "$INCOMING" "$DESTINATION/Culprit.app"
echo "installed $DESTINATION/Culprit.app"
