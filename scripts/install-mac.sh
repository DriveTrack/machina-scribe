#!/usr/bin/env bash
# Builds the Mac app and installs it to /Applications.
#
# Also nudges macOS into re-reading the icon. LaunchServices caches an icon per
# bundle, so a rebuilt app at a path it has already seen keeps showing the old
# one -- which looks exactly like the icon never got built.
set -euo pipefail
cd "$(dirname "$0")/../apps"

osascript -e 'quit app "Scribe"' 2>/dev/null || true
osascript -e 'quit app "Scribe-macOS"' 2>/dev/null || true
sleep 1

xcodebuild -project Scribe.xcodeproj -scheme Scribe-macOS -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/mac build \
  | grep -E 'error:|BUILD' || true

SRC=build/mac/Build/Products/Debug/Scribe-macOS.app
DEST=/Applications/Scribe.app
[ -d "$SRC" ] || { echo "build produced no app" >&2; exit 1; }

rm -rf "$DEST"
cp -R "$SRC" "$DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Scribe" "$DEST/Contents/Info.plist" 2>/dev/null || true
touch "$DEST"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST" 2>/dev/null || true
killall Dock 2>/dev/null || true

echo "installed to $DEST"
