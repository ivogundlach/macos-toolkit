#!/bin/bash
# Build + install CopyPath.app with embedded FinderSync extension (CLT-only).
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx14.0"
SIGN_ID="Ivo Market Dev"
APP=".build/CopyPath.app"
APPEX="$APP/Contents/PlugIns/CopyPathFinderExt.appex"

rm -rf .build
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"

# --- Host app binary ---
swiftc -sdk "$SDK" -target "$TARGET" \
  Sources/main.swift -o "$APP/Contents/MacOS/CopyPath"

# --- Extension binary (app-extension entry point) ---
swiftc -sdk "$SDK" -target "$TARGET" \
  -application-extension -parse-as-library \
  -module-name CopyPathFinderExt \
  Extension/FinderSync.swift \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -framework FinderSync \
  -o "$APPEX/Contents/MacOS/CopyPathFinderExt"

# --- Host app Info.plist ---
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CopyPath</string>
  <key>CFBundleIdentifier</key><string>com.ivo.CopyPath</string>
  <key>CFBundleName</key><string>CopyPath</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

# --- Extension Info.plist ---
cat > "$APPEX/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSUIElement</key><true/>
  <key>CFBundleExecutable</key><string>CopyPathFinderExt</string>
  <key>CFBundleIdentifier</key><string>com.ivo.CopyPath.FinderExt</string>
  <key>CFBundleName</key><string>CopyPathFinderExt</string>
  <key>CFBundleDisplayName</key><string>Copy Path</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionAttributes</key><dict/>
    <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
    <key>NSExtensionPrincipalClass</key><string>CopyPathFinderExt.FinderSync</string>
  </dict>
</dict></plist>
EOF

# --- Sign (inside-out); appex must be sandboxed or pkd rejects it ---
cat > .build/ext.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
EOF
codesign --force --sign "$SIGN_ID" --entitlements .build/ext.entitlements "$APPEX"
codesign --force --sign "$SIGN_ID" "$APP"

# --- Install ---
if [ "${NO_DEPLOY:-0}" != "1" ]; then
  rm -rf /Applications/CopyPath.app
  cp -R "$APP" /Applications/
  pluginkit -a /Applications/CopyPath.app/Contents/PlugIns/CopyPathFinderExt.appex
  pluginkit -e use -i com.ivo.CopyPath.FinderExt
  echo "Installed /Applications/CopyPath.app and enabled extension."
fi
