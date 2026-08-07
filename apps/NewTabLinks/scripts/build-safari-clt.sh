#!/usr/bin/env bash
set -euo pipefail

# Hand-build the New Tab Links Safari app + web-extension appex with
# Command Line Tools only (no Xcode project). Signs with Apple Development and
# installs to /Applications.
# Usage: ./scripts/build-safari-clt.sh          (NO_DEPLOY=1 to skip install)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build-clt"
APP="$BUILD/NewTabLinks.app"
APPEX="$APP/Contents/PlugIns/NewTabLinks Extension.appex"
SDK="$(xcrun --show-sdk-path)"
VERSION="$(/usr/bin/python3 -c "import json;print(json.load(open('$ROOT/extension/manifest.json'))['version'])")"
SIGN_ID="Apple Development: you@icloud.example.com (7L2AWL849H)"

rm -rf "$BUILD"
mkdir -p "$APPEX/Contents/MacOS" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. Icons (rendered once, reused on rebuilds)
ICON1024="$ROOT/extension/icons/icon-1024.png"
if [ ! -f "$ICON1024" ]; then
  mkdir -p "$ROOT/extension/icons"
  swift "$SCRIPT_DIR/render-icon.swift" "$ICON1024"
  for s in 48 128 256 512; do
    sips -z "$s" "$s" "$ICON1024" --out "$ROOT/extension/icons/icon-$s.png" >/dev/null
  done
fi

# 2. Compile the appex handler
swiftc -parse-as-library -application-extension \
  -sdk "$SDK" -target arm64-apple-macosx11.0 \
  -module-name NewTabLinks_Extension \
  "$ROOT/app/SafariWebExtensionHandler.swift" \
  -framework SafariServices \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/NewTabLinks Extension"

mkdir -p "$APPEX/Contents/Resources"
cp -R "$ROOT/extension/." "$APPEX/Contents/Resources/"

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key><string>New Tab Links</string>
	<key>CFBundleExecutable</key><string>NewTabLinks Extension</string>
	<key>CFBundleIdentifier</key><string>dev.ivogundlach.NewTabLinks.Extension</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>NewTabLinks Extension</string>
	<key>CFBundlePackageType</key><string>XPC!</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
		<key>NSExtensionPrincipalClass</key><string>NewTabLinks_Extension.SafariWebExtensionHandler</string>
	</dict>
</dict>
</plist>
PLIST

# 3. Compile the host app
swiftc -parse-as-library \
  -sdk "$SDK" -target arm64-apple-macosx11.0 \
  "$ROOT/app/MainCLT.swift" \
  -framework AppKit -framework SafariServices \
  -o "$APP/Contents/MacOS/NewTabLinks"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>NewTabLinks</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>dev.ivogundlach.NewTabLinks</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>New Tab Links</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 4. App icon
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON1024" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$ICON1024" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 5. Sign (appex first, then app) — appexes must be sandboxed or pkd rejects them
cat > "$BUILD/ext.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
ENT
codesign --force --options runtime --entitlements "$BUILD/ext.entitlements" --sign "$SIGN_ID" "$APPEX"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP (v$VERSION)"

# 6. Install
if [ "${NO_DEPLOY:-0}" != "1" ]; then
  rm -rf "/Applications/NewTabLinks.app"
  cp -R "$APP" /Applications/
  open "/Applications/NewTabLinks.app"
  echo "Installed /Applications/NewTabLinks.app"
fi
