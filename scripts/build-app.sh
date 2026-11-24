#!/bin/bash
# Builds build/Kopi.app (universal: Apple silicon + Intel) and build/Kopi.zip.
#
#   scripts/build-app.sh [version]
#
# Environment:
#   KOPI_SIGN_IDENTITY  codesign identity (default "-" = ad-hoc). Use a stable identity, even a
#                       self-signed one, so macOS keeps Kopi's permissions across rebuilds.
#   KOPI_ARCHS          architectures to build (default "arm64 x86_64").
#   KOPI_TIMESTAMP=1    adds a secure timestamp to the signature (needed for notarization).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${KOPI_SIGN_IDENTITY:--}"

arch_flags=()
for arch in ${KOPI_ARCHS:-arm64 x86_64}; do
    arch_flags+=(--arch "$arch")
done

swift build -c release "${arch_flags[@]}"
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

APP=build/Kopi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Kopi" "$APP/Contents/MacOS/Kopi"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [ "${KOPI_TIMESTAMP:-0}" = 1 ]; then timestamp=--timestamp; else timestamp=--timestamp=none; fi
codesign --force --options runtime "$timestamp" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

rm -f build/Kopi.zip
ditto -c -k --keepParent "$APP" build/Kopi.zip

if [ "$IDENTITY" = "-" ]; then signer="ad-hoc"; else signer="$IDENTITY"; fi
echo "Built $APP $VERSION ($BUILD_NUMBER), $(lipo -archs "$APP/Contents/MacOS/Kopi"), signed $signer"
