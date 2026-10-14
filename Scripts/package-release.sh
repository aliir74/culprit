#!/usr/bin/env bash
# Build a universal Culprit.app and zip it as build/Culprit-<version>.zip; prints the zip path.
# ditto, not zip: zip drops the extended attributes that hold the code signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
STAGE="$("$ROOT/Scripts/build-app.sh" --universal)"
ZIP="$ROOT/build/Culprit-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"
echo "$ZIP"
