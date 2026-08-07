#!/bin/bash
# make_icon.sh — render the app icon and assemble Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ rendering 1024px icon…"
xcrun --sdk macosx swiftc -O tools/make_icon.swift -o build/make_icon 2>/dev/null || \
  xcrun --sdk macosx swiftc tools/make_icon.swift -o build/make_icon
mkdir -p build Resources
./build/make_icon Resources/icon_1024.png

echo "▸ building iconset…"
ICON="Resources/AppIcon.iconset"
rm -rf "$ICON"; mkdir -p "$ICON"
gen() { sips -z "$1" "$1" Resources/icon_1024.png --out "$ICON/$2" >/dev/null; }
gen 16  icon_16x16.png
gen 32  icon_16x16@2x.png
gen 32  icon_32x32.png
gen 64  icon_32x32@2x.png
gen 128 icon_128x128.png
gen 256 icon_128x128@2x.png
gen 256 icon_256x256.png
gen 512 icon_256x256@2x.png
gen 512 icon_512x512.png
cp Resources/icon_1024.png "$ICON/icon_512x512@2x.png"

echo "▸ iconutil → AppIcon.icns…"
iconutil -c icns "$ICON" -o Resources/AppIcon.icns
rm -rf "$ICON"
echo "✓ wrote Resources/AppIcon.icns"
