#!/usr/bin/env bash
# Regenerate AppIcon.icns from Icon/AppIcon.svg (rsvg-convert + sips + iconutil).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/Icon/AppIcon.svg"
MASTER="$ROOT/Icon/AppIcon-1024.png"
ICONSET="$ROOT/Icon/AppIcon.iconset"
ICNS="$ROOT/Icon/AppIcon.icns"

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)"; exit 1; }

rsvg-convert -w 1024 -h 1024 "$SVG" -o "$MASTER"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
gen() { sips -z "$2" "$2" "$MASTER" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png       16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png     128
gen icon_128x128@2x.png  256
gen icon_256x256.png     256
gen icon_256x256@2x.png  512
gen icon_512x512.png     512
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Wrote $ICNS"
