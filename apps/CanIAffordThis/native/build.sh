#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Runway"
EXECUTABLE="Runway"
BUILD_DIR=".build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"

mkdir -p "$BUILD_DIR" Resources
xcrun swift scripts/make-icon.swift

ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  pixels="${spec%% *}"
  filename="${spec#* }"
  sips -z "$pixels" "$pixels" Resources/icon-1024.png \
    --out "$ICONSET/$filename" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx26.0 \
  Sources/*.swift \
  -o "$BUILD_DIR/$EXECUTABLE"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$EXECUTABLE" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

if security find-certificate -c "Ivo Market Dev" >/dev/null 2>&1; then
  codesign --force --deep --sign "Ivo Market Dev" "$BUNDLE"
else
  codesign --force --deep --sign - "$BUNDLE"
fi

if [[ "${NO_DEPLOY:-0}" != "1" ]]; then
  osascript -e 'tell application "Can I Afford This" to quit' >/dev/null 2>&1 || true
  osascript -e 'tell application "Runway" to quit' >/dev/null 2>&1 || true
  rm -rf "/Applications/Can I Afford This.app"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$BUNDLE" "/Applications/$APP_NAME.app"
fi

echo "Built and installed: /Applications/$APP_NAME.app"
