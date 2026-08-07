#!/bin/bash
# Build UsageQueue.app with CLT-only swiftc, sign with Ivo Market Dev, install to /Applications.
# NO_DEPLOY=1 to skip the install step.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=UsageQueue
BUILD=.build
BUNDLE="$BUILD/$APP.app"

mkdir -p "$BUILD"
swiftc -parse-as-library -O \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macosx26.0 \
  Sources/main.swift \
  Sources/RefractiveGlass.swift \
  -o "$BUILD/$APP"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD/$APP" "$BUNDLE/Contents/MacOS/$APP"
cp Info.plist "$BUNDLE/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

if security find-certificate -c "Ivo Market Dev" >/dev/null 2>&1; then
  codesign --force --deep --sign "Ivo Market Dev" "$BUNDLE"
else
  codesign --force --deep --sign - "$BUNDLE"
fi
echo "Built: $BUNDLE"

if [[ "${NO_DEPLOY:-0}" != "1" ]]; then
  osascript -e 'tell application "UsageQueue" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/$APP.app"
  cp -R "$BUNDLE" "/Applications/$APP.app"
  echo "Installed: /Applications/$APP.app"
fi
