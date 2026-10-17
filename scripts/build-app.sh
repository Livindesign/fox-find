#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=release
if [[ "${1:-}" == --debug ]]; then CONFIGURATION=debug; fi
APP_PATH="$PROJECT_DIR/build/$CONFIGURATION/Fox Find.app"
bash scripts/build-llama.sh
swift build -c "$CONFIGURATION" --product foxfind-semantic-worker
swift build -c "$CONFIGURATION" --product FoxFind
BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Helpers"
cp "$BINARY_DIR/foxfind-semantic-worker" "$APP_PATH/Contents/Helpers/foxfind-semantic-worker"
cp "$BINARY_DIR/FoxFind" "$APP_PATH/Contents/MacOS/FoxFind"
if [[ "$CONFIGURATION" == release ]]; then strip -S "$APP_PATH/Contents/MacOS/FoxFind"; fi
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp -R "$BINARY_DIR/FoxFind_OilFindApp.bundle" "$APP_PATH/Contents/Resources/"
cp Resources/LocalFind.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE-Oil-Find.txt"
cp NOTICE.md "$APP_PATH/Contents/Resources/NOTICE.md"
cp -R LICENSES "$APP_PATH/Contents/Resources/"
cp THIRD-PARTY-NOTICES.md "$APP_PATH/Contents/Resources/THIRD-PARTY-NOTICES.md"
codesign --force --sign "${LOCALFIND_SIGN_IDENTITY:--}" --identifier app.localfind.desktop.semantic "$APP_PATH/Contents/Helpers/foxfind-semantic-worker"
codesign --force --sign "${LOCALFIND_SIGN_IDENTITY:--}" --identifier app.localfind.desktop "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
