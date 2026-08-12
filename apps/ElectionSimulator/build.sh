#!/bin/bash
# Build Psephos (Election Simulator) as a macOS .app using swiftc.
# (SwiftPM is broken in this Command Line Tools install; we compile + bundle by hand.)
set -euo pipefail
cd "$(dirname "$0")"

BIN="Psephos"
APPNAME="Psephos.app"
TARGET="arm64-apple-macosx26.0"

echo "▸ regenerating embedded data…"
python3 tools/gen_data.py

echo "▸ compiling Swift sources…"
mkdir -p build
xcrun --sdk macosx swiftc \
    -parse-as-library -O \
    -swift-version 5 \
    -target "$TARGET" \
    Sources/*.swift \
    -o "build/$BIN"

echo "▸ assembling app bundle…"
APP="build/$APPNAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$BIN" "$APP/Contents/MacOS/$BIN"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Psephos</string>
  <key>CFBundleDisplayName</key><string>Psephos — Election Simulator</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIdentifier</key><string>com.ivo.psephos</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
</dict></plist>
PLIST

# Certificate, not ad-hoc: an ad-hoc signature is keyed to the exact compiled bytes,
# so every rebuild looks like a different app to macOS and silently drops whatever
# permissions the app held. Check the fleet with `signing-audit`.
if security find-identity -v -p codesigning | grep -q "Ivo Market Dev"; then
  codesign --force --deep -s "Ivo Market Dev" --timestamp=none "$APP" >/dev/null 2>&1 || true
else
  echo "WARNING: 'Ivo Market Dev' certificate missing; ad-hoc signing means permissions break on rebuild." >&2
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
fi
echo "✓ built $APP"
