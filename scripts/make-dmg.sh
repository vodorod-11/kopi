#!/bin/bash
# Packs build/Kopi.app into build/Kopi-<version>.dmg: a window with Kopi and an Applications link.
#
#   scripts/build-app.sh 1.2.0 && scripts/make-dmg.sh
#
# Environment:
#   KOPI_SIGN_IDENTITY  also signs the DMG when set to a real identity (not "-").
#   KOPI_TIMESTAMP=1    adds a secure timestamp (needed for notarization).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Kopi.app
if [ ! -d "$APP" ]; then
    echo "build/Kopi.app is missing: run scripts/build-app.sh first" >&2
    exit 1
fi
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="build/Kopi-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Kopi.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
# hdiutil sometimes fails with "Resource busy" on CI machines; try a few times.
for attempt in 1 2 3; do
    if hdiutil create -volname "Kopi $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO \
        -imagekey zlib-level=9 -ov "$DMG" >/dev/null; then
        break
    fi
    [ "$attempt" = 3 ] && exit 1
    echo "hdiutil failed, retrying ($attempt)" >&2
    sleep 5
done

IDENTITY="${KOPI_SIGN_IDENTITY:--}"
if [ "$IDENTITY" != "-" ]; then
    if [ "${KOPI_TIMESTAMP:-0}" = 1 ]; then timestamp=--timestamp; else timestamp=--timestamp=none; fi
    codesign --force "$timestamp" --sign "$IDENTITY" "$DMG"
fi

hdiutil verify "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
shasum -a 256 "$DMG"
