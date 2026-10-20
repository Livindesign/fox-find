#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
source scripts/swift-environment.sh
CONFIGURATION=release
if [[ "${1:-}" == --debug ]]; then CONFIGURATION=debug; fi
OUTPUT_PATH="$PROJECT_DIR/build/$CONFIGURATION/Fox Find.app"
BUILD_JOBS="${FOX_BUILD_JOBS:-1}"
if ! [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then echo 'FOX_BUILD_JOBS must be a positive integer' >&2; exit 1; fi
bash scripts/build-llama.sh
swift build -c "$CONFIGURATION" --jobs "$BUILD_JOBS" --product foxfind-semantic-worker
swift build -c "$CONFIGURATION" --jobs "$BUILD_JOBS" --product FoxFind
BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/build/$CONFIGURATION/.app-staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_PATH="$STAGING_DIR/Fox Find.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Helpers"
cp "$BINARY_DIR/foxfind-semantic-worker" "$APP_PATH/Contents/Helpers/foxfind-semantic-worker"
cp "$BINARY_DIR/FoxFind" "$APP_PATH/Contents/MacOS/FoxFind"
if [[ "$CONFIGURATION" == release ]]; then strip -S "$APP_PATH/Contents/MacOS/FoxFind"; fi
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp -R "$BINARY_DIR/FoxFind_FoxFindApp.bundle" "$APP_PATH/Contents/Resources/"
cp Resources/LocalFind.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE-Oil-Find.txt"
cp NOTICE.md "$APP_PATH/Contents/Resources/NOTICE.md"
cp -R LICENSES "$APP_PATH/Contents/Resources/"
cp THIRD-PARTY-NOTICES.md "$APP_PATH/Contents/Resources/THIRD-PARTY-NOTICES.md"
SIGN_ARGS=(--force --sign "${LOCALFIND_SIGN_IDENTITY:--}")
if [[ "${LOCALFIND_SIGN_IDENTITY:--}" != - ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" --identifier app.localfind.desktop.semantic "$APP_PATH/Contents/Helpers/foxfind-semantic-worker"
codesign "${SIGN_ARGS[@]}" --identifier app.localfind.desktop "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
# Replace only the generated bundle after validation. Never merge old SwiftPM
# resource bundles into a new build, or touch the installed application here.
if [[ -e "$OUTPUT_PATH" ]]; then mv "$OUTPUT_PATH" "$STAGING_DIR/previous.app"; fi
if ! mv "$APP_PATH" "$OUTPUT_PATH"; then
    if [[ -e "$STAGING_DIR/previous.app" ]]; then mv "$STAGING_DIR/previous.app" "$OUTPUT_PATH"; fi
    exit 1
fi
printf '%s\n' "$OUTPUT_PATH"
