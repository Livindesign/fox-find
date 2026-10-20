#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-environment.sh
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'This preview package requires an Apple silicon Mac.' >&2
  exit 1
fi
bash scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
RELEASE_ID="${FOX_FIND_RELEASE_ID:-$VERSION-preview.1}"
[[ "$RELEASE_ID" =~ ^[0-9A-Za-z.-]+$ ]] || { echo 'Invalid release ID' >&2; exit 1; }
APP='build/release/Fox Find.app'
mkdir -p dist
ARCHIVE="dist/Fox-Find-$RELEASE_ID-macOS-arm64.zip"
codesign --verify --deep --strict "$APP"
test -f "$APP/Contents/Resources/LICENSES/Oil-Find-MIT.txt"
test -f "$APP/Contents/Resources/LICENSES/DigUp-MIT.txt"
test -f "$APP/Contents/Resources/LICENSES/llama.cpp-hash-xxhash.txt"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ARCHIVE"
unzip -tq "$ARCHIVE"
(cd dist && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt)
if [[ -f "$HOME/Library/Application Support/Fox Find Release/ed25519.key" ]]; then
  swift scripts/sign-update.swift "$ARCHIVE" Resources/Info.plist "v$RELEASE_ID" Resources/UpdateNotes.json dist/fox-find-update.json
fi
echo "$ARCHIVE"
