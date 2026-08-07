#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Warm Corners.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r source_file; do
  SOURCES+=("$source_file")
done < <(find "$ROOT/Sources" -name '*.swift' | sort)

echo "Compiling Warm Corners (${#SOURCES[@]} sources)..."
# No -parse-as-library: Sources/main.swift is top-level code.
xcrun swiftc \
  -swift-version 5 \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  "${SOURCES[@]}" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$BUILD/WarmCorners"

cp "$BUILD/WarmCorners" "$APP/Contents/MacOS/WarmCorners"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

if [ ! -f "$ROOT/Icon/AppIcon.icns" ] || [ "$ROOT/Icon/AppIcon.svg" -nt "$ROOT/Icon/AppIcon.icns" ]; then
  "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

chmod +x "$APP/Contents/MacOS/WarmCorners"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ "${NO_DEPLOY:-0}" == "1" ]]; then
  echo "Built without signing or installing: $APP"
  exit 0
fi

# Stable identity: login-item registration and TCC grants are keyed to the signature.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Ivo Market Dev}"
codesign --force --sign "$SIGNING_IDENTITY" "$APP" >/dev/null

if pgrep -x WarmCorners >/dev/null 2>&1; then
  pkill -x WarmCorners 2>/dev/null || true
  sleep 1
fi

rm -rf "/Applications/Warm Corners.app"
cp -R "$APP" "/Applications/Warm Corners.app"
codesign --verify --strict --verbose=2 "/Applications/Warm Corners.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/Warm Corners.app"

echo "Built and installed: /Applications/Warm Corners.app"
