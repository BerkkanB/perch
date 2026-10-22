#!/usr/bin/env bash
# Builds Perch.app into ./build.
#   CONFIG=debug ./scripts/build-app.sh      debug build
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh   sign with a real identity
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Perch"
BUNDLE_ID="${BUNDLE_ID:-com.berkkanbutun.perch}"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

echo "› Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "› Generating app icon…"
  ./scripts/make-icon.sh
fi

APP="build/$APP_NAME.app"
echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "› Signing (${SIGN_IDENTITY})"
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$APP" >/dev/null

echo "✓ Built $APP ($VERSION, build $BUILD_NUMBER)"
