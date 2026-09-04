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

SRC=build/mac/Build/Products/Debug/Scribe.app
DEST=/Applications/Scribe.app
[ -d "$SRC" ] || { echo "build produced no app" >&2; exit 1; }

rm -rf "$DEST"
cp -R "$SRC" "$DEST"
touch "$DEST"

# Never edit anything inside the bundle here. Changing Info.plist after signing
# invalidates the signature, and a sandboxed app whose signature does not verify
# is killed on launch by libsystem_secinit -- which reads as a mystery crash.
if ! codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  echo "signature does not verify after install; refusing to leave a broken app" >&2
  codesign --verify --deep --strict --verbose=2 "$DEST" || true
  exit 1
fi
echo "signature verifies"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST" 2>/dev/null || true
killall Dock 2>/dev/null || true

echo "installed to $DEST"
