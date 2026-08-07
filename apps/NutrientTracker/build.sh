#!/bin/bash
# Build NutrientTracker.app from source using the Swift Command Line Tools.
# No Xcode required. Produces build/NutrientTracker.app (arm64).
# Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP="NutrientTracker"
BUNDLE_ID="com.ivo.nutrienttracker"
VERSION="1.0"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"
OUT="build"
APPDIR="$OUT/$APP.app"
INSTALL=0

case "${1:-}" in
  "") ;;
  --install) INSTALL=1 ;;
  *)
    echo "Usage: ./build.sh [--install]" >&2
    exit 64
    ;;
esac

echo "› SDK: $SDK"
rm -rf "$APPDIR" "$OUT/$APP"
mkdir -p "$OUT" "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

echo "› Compiling…"
SRCS=()
while IFS= read -r -d '' f; do SRCS+=("$f"); done < <(find Sources -name '*.swift' -print0)
swiftc -parse-as-library -O -sdk "$SDK" -target "$TARGET" \
  "${SRCS[@]}" -o "$APPDIR/Contents/MacOS/$APP"

echo "› Bundling resources…"
cp Resources/usda_foods.sqlite "$APPDIR/Contents/Resources/"
# App icon: regenerate from master PNG if iconutil is available, else use checked-in icns.
if command -v iconutil >/dev/null 2>&1 && [[ -f Resources/AppIcon.png ]]; then
  ICONSET="$OUT/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec; sips -z "$1" "$1" Resources/AppIcon.png --out "$ICONSET/$2.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APPDIR/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
elif [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APPDIR/Contents/Resources/"
fi

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>Nutrient Tracker</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
</dict>
</plist>
PLIST

echo "› Ad-hoc code signing…"
codesign --force --deep --sign - "$APPDIR" 2>/dev/null || echo "  (codesign skipped)"

if [[ "$INSTALL" -eq 1 ]]; then
  echo "› Installing to /Applications…"
  rm -rf "/Applications/$APP.app"
  mv "$APPDIR" "/Applications/"
  echo "✓ Installed /Applications/$APP.app"
else
  echo "✓ Built $APPDIR"
fi
