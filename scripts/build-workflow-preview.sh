#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
source scripts/swift-environment.sh
if [[ "${1:-}" != --skip-build ]]; then
  bash scripts/build-llama.sh
  nice -n 15 swift build -c debug --jobs 1 --product FoxFind
fi
TASK_BIN="$(swift build -c debug --show-bin-path)"
TASK_APP="$TASK_ROOT/build/workflow-preview/Fox Find Workflow Preview.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN/FoxFind" "$TASK_APP/Contents/MacOS/FoxFindCore"
cp -R "$TASK_BIN/FoxFind_FoxFindApp.bundle" "$TASK_APP/Contents/Resources/"
cp Resources/LocalFind.icns "$TASK_APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.localfind.workflow-preview' "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable FoxFindCore' "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Fox Find Workflow Preview' "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Fox Find Workflow Preview' "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.0.1-dev' "$TASK_APP/Contents/Info.plist"
# Inherit the current build number from Info.plist instead of presenting an old
# preview build as the latest candidate.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$TASK_APP/Contents/Info.plist"
# The bundle ID selects the DEBUG-only synthetic demo before LocalFindExtension
# initialization. Keep the Mach-O binary as the app executable so Launch Services
# and Accessibility share the same native process identity.
rm -f "$TASK_APP/Contents/MacOS/FoxFindPreview"
cp LICENSE "$TASK_APP/Contents/Resources/LICENSE-Oil-Find.txt"
cp NOTICE.md THIRD-PARTY-NOTICES.md "$TASK_APP/Contents/Resources/"
cp -R LICENSES "$TASK_APP/Contents/Resources/"
codesign --force --sign - "$TASK_APP/Contents/MacOS/FoxFindCore"
codesign --force --sign - "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
printf '%s\n' "$TASK_APP"
