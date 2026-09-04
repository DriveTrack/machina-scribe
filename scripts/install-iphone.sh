#!/usr/bin/env bash
# Builds a signed device build and installs it on a connected iPhone.
#
# Needs apps/Local.xcconfig with your DEVELOPMENT_TEAM (see the .example), and
# the phone unlocked, trusted, and preferably plugged in over USB -- the
# network tunnel drops constantly and gives confusing "connection reset" errors.
set -euo pipefail
cd "$(dirname "$0")/../apps"

if [ ! -f Local.xcconfig ]; then
  echo "apps/Local.xcconfig is missing. Copy Local.xcconfig.example and set your team id." >&2
  exit 1
fi

NAME="${1:-Jose’s iPhone}"
UDID=$(xcrun xctrace list devices 2>/dev/null \
  | grep -v Simulator | grep "$NAME" | head -1 \
  | sed -E 's/.*\(([0-9A-Fa-f-]{8,})\)$/\1/')

if [ -z "$UDID" ]; then
  echo "No device matching \"$NAME\". Connected devices:" >&2
  xcrun xctrace list devices 2>/dev/null | sed -n '/== Devices ==/,/== Simulators ==/p' >&2
  exit 1
fi
echo "device: $NAME ($UDID)"

xcodebuild -project Scribe.xcodeproj -scheme Scribe-iOS \
  -destination 'generic/platform=iOS' -derivedDataPath build/device \
  -allowProvisioningUpdates build \
  | grep -E 'error:|BUILD' || true

# PRODUCT_NAME changed the bundle name; accept either.
APP=build/device/Build/Products/Debug-iphoneos/Scribe.app
[ -d "$APP" ] || APP=build/device/Build/Products/Debug-iphoneos/Scribe-iOS.app
[ -d "$APP" ] || { echo "build produced no app" >&2; exit 1; }

echo "installing…"
# Works over Wi-Fi as well as USB: devicectl brings the tunnel up on demand,
# even when `list devices` reports the phone as disconnected. It needs the
# phone unlocked and on the same network, and a longer timeout than the
# default, because establishing that tunnel is not instant.
xcrun devicectl device install app --timeout 120 --device "$UDID" "$APP"
echo
echo "Installed. On the phone: Settings → General → VPN & Device Management →"
echo "trust the developer certificate, then open Scribe."
