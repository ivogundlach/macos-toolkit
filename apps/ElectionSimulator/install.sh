#!/bin/bash
# Build and install Psephos.app into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="Psephos.app"
SRC="build/$APPNAME"
DST="/Applications/$APPNAME"
TMP="/Applications/.Psephos.installing.$$"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

./build.sh
codesign --verify --deep --strict --verbose=2 "$SRC"

rm -rf "$TMP"
ditto "$SRC" "$TMP"
xattr -dr com.apple.quarantine "$TMP" 2>/dev/null || true

plutil -lint "$TMP/Contents/Info.plist" >/dev/null
test -x "$TMP/Contents/MacOS/Psephos"
test -f "$TMP/Contents/Resources/AppIcon.icns"
codesign --verify --deep --strict --verbose=2 "$TMP"

rm -rf "$DST"
mv "$TMP" "$DST"
trap - EXIT

codesign --verify --deep --strict --verbose=2 "$DST"
echo "installed $DST"
