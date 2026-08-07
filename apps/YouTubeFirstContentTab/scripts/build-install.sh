#!/bin/zsh
# Build, verify, and install the Safari extension with Ivo's development team.

set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/Safari/YouTube First Content Tab/YouTube First Content Tab.xcodeproj"
BUILD_APP="$ROOT/.build/Build/Products/Release/YouTube First Content Tab.app"
EXTENSION="$BUILD_APP/Contents/PlugIns/YouTube First Content Tab Extension.appex"
INSTALLED_APP="/Applications/YouTube Defaults.app"
OLD_INSTALLED_APP="/Applications/YouTube First Content Tab.app"
TEAM_ID="Q2X7X86GYR"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

cleanup_build_registration() {
  pluginkit -r "$EXTENSION" 2>/dev/null || true
  "$LSREGISTER" -u "$BUILD_APP" 2>/dev/null || true
}
trap cleanup_build_registration EXIT

node --check "$ROOT/Extension/content.js"
cmp "$ROOT/Extension/content.js" "$ROOT/Safari/YouTube First Content Tab/YouTube First Content Tab Extension/Resources/content.js"
cmp "$ROOT/Extension/manifest.json" "$ROOT/Safari/YouTube First Content Tab/YouTube First Content Tab Extension/Resources/manifest.json"
diff -qr "$ROOT/Extension/icons" "$ROOT/Safari/YouTube First Content Tab/YouTube First Content Tab Extension/Resources/icons"

xcodebuild \
  -project "$PROJECT" \
  -scheme "YouTube First Content Tab" \
  -configuration Release \
  -derivedDataPath "$ROOT/.build" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Automatic \
  clean build

verify_team() {
  local bundle="$1"
  local signature
  codesign --verify --deep --strict "$bundle"
  signature="$(codesign -d --verbose=4 "$bundle" 2>&1)"
  [[ "$signature" == *"TeamIdentifier=$TEAM_ID"* ]]
}

# Refuse to install a build Safari would hide from its Extensions settings.
verify_team "$BUILD_APP"
verify_team "$EXTENSION"

if [[ -d "$OLD_INSTALLED_APP" ]]; then
  pluginkit -r "$OLD_INSTALLED_APP/Contents/PlugIns/YouTube First Content Tab Extension.appex" 2>/dev/null || true
  "$LSREGISTER" -u "$OLD_INSTALLED_APP" 2>/dev/null || true
  mv "$OLD_INSTALLED_APP" "$INSTALLED_APP"
fi
/usr/bin/ditto --rsrc --extattr --acl "$BUILD_APP" "$INSTALLED_APP"
"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/YouTube First Content Tab Extension.appex"

verify_team "$INSTALLED_APP"
cmp "$ROOT/Extension/content.js" "$INSTALLED_APP/Contents/PlugIns/YouTube First Content Tab Extension.appex/Contents/Resources/content.js"
cmp "$ROOT/Extension/manifest.json" "$INSTALLED_APP/Contents/PlugIns/YouTube First Content Tab Extension.appex/Contents/Resources/manifest.json"
diff -qr "$ROOT/Extension/icons" "$INSTALLED_APP/Contents/PlugIns/YouTube First Content Tab Extension.appex/Contents/Resources/icons"

echo "Installed signed Safari extension: $INSTALLED_APP"
