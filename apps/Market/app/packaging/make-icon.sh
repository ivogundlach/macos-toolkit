#!/bin/zsh
# make-icon.sh — rasterize icon.svg into a full .iconset and produce Market.icns.
#
# CLT-only pipeline (no Xcode, no Pillow): sips rasterizes the SVG at each
# required size, iconutil packs the .iconset into a single .icns.
#
# Output: app/packaging/Market.icns (also leaves Market.iconset/ for inspection).
set -e

HERE="${0:A:h}"
SVG="$HERE/icon.svg"
SET="$HERE/Market.iconset"
ICNS="$HERE/Market.icns"

[[ -f "$SVG" ]] || { echo "missing $SVG" >&2; exit 1; }

rm -rf "$SET" "$ICNS"
mkdir -p "$SET"

# Apple iconset matrix: 16,32,128,256,512 each at 1x + @2x.
render() {  # render <px> <outfile>
  sips -s format png -z "$1" "$1" "$SVG" --out "$SET/$2" >/dev/null
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$ICNS"
echo "icon: $ICNS"
ls -l "$ICNS"
