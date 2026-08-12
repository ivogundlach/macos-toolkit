#!/bin/zsh
# Builds and installs /Applications/AutoInstall DMG.app from source.
#
# This app used to have no build script: it was edited in Script Editor and saved
# straight over the installed copy. Saving from Script Editor re-signs the bundle
# ad-hoc, and an ad-hoc signature is keyed to the exact compiled bytes -- so macOS
# saw a brand-new app after every edit and silently dropped its permission to
# control other apps. This script rebuilds the whole bundle deterministically and
# signs it with the "Ivo Market Dev" certificate, whose signature stays valid across
# rebuilds. Edit src/main.applescript here, run ./build.sh, never edit the installed
# app in place.
#
# Usage:
#   ./build.sh              build, sign, and install to /Applications
#   NO_DEPLOY=1 ./build.sh  build and sign only, leave /Applications alone
#   ./build.sh --version    read-only health report (never rebuilds anything)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AutoInstall DMG"
BUNDLE_ID="com.ivogundlach.autoinstalldmg"
SIGNING_IDENTITY="Ivo Market Dev"
DEST="/Applications/$APP_NAME.app"

# --version must never rebuild. Tool Status Dashboard executes a registered binary's
# health check every 5 minutes under a 5s timeout; a build script that ignores its
# arguments and falls through to the build would destroy its own output on a loop.
# That is exactly what happened to mail-assistant-app-build on 2026-08-08.
if [[ "${1:-}" == "--version" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print "autoinstall-dmg build ($APP_NAME)"
  [[ -d "$DEST" ]] || { print "  FAIL: $DEST is not installed"; exit 1; }
  [[ -x "$DEST/Contents/Resources/worker.sh" ]] || { print "  FAIL: worker.sh missing; installs would never run"; exit 1; }
  dr="$(codesign -d -r- "$DEST" 2>&1 | grep -m1 'designated' || true)"
  [[ "$dr" == *"certificate leaf"* ]] || { print "  FAIL: not certificate-signed, permissions die on the next rebuild -- $dr"; exit 1; }
  print "  ok: installed, worker present, $dr"
  exit 0
fi

security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || { print -u2 "signing identity not in keychain: $SIGNING_IDENTITY"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"

# osacompile turns the AppleScript into an applet; because main.applescript defines
# an `on open` handler it produces a droplet, which is what makes dropping .dmg files
# onto it work.
print "› Compiling droplet…"
osacompile -o "$APP" "$ROOT/src/main.applescript"

print "› Adding resources…"
install -m 755 "$ROOT/src/worker.sh" "$APP/Contents/Resources/worker.sh"
cp "$ROOT/resources/droplet.icns" "$APP/Contents/Resources/droplet.icns"
cp "$ROOT/resources/Assets.car" "$APP/Contents/Resources/Assets.car"

print "› Applying bundle settings…"
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PL" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PL"
# LSUIElement keeps it out of the Dock and the app switcher: it is a drop target and
# a background installer, never a window the user looks at.
/usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$PL" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PL"

# Claim .dmg files specifically. osacompile's default entry claims every file type
# ("*" plus the "****" OSType), which would offer this droplet as a handler for
# unrelated documents.
/usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes" "$PL" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleDocumentTypes array" \
  -c "Add :CFBundleDocumentTypes:0 dict" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" \
  -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Owner" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeExtensions array" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeExtensions:0 string dmg" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string com.apple.disk-image" \
  "$PL"
# The previously installed copy listed com.apple.disk-image five times; duplicates in
# that array mean nothing to Launch Services, so it is written once here.

plutil -lint "$PL" >/dev/null

# Certificate, never ad-hoc. The whole point of this script.
print "› Signing…"
codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

dr="$(codesign -d -r- "$APP" 2>&1 | grep -m1 'designated' || true)"
[[ "$dr" == *"certificate leaf"* ]] || { print -u2 "refusing to install: signature is not certificate-backed -- $dr"; exit 1; }

if [[ "${NO_DEPLOY:-0}" == "1" ]]; then
  OUT="$ROOT/build/$APP_NAME.app"
  mkdir -p "$ROOT/build"; rm -rf "$OUT"; cp -R "$APP" "$OUT"
  print "✓ built (not installed): ${OUT/#$HOME/~}"
  exit 0
fi

print "› Installing to /Applications…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
print "✓ installed $DEST"
codesign -d -r- "$DEST" 2>&1 | grep -m1 'designated'
