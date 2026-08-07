#!/bin/zsh
# build-app.sh — build, sign, and install Market.app.
#
# Steps:
#   1. rebuild the release binary via app/scripts/build.sh release (the CLT-rpath
#      wrapper; never bare `swift build`).
#   2. build the icon (make-icon.sh -> Market.icns) if missing or stale.
#   3. assemble Contents/{MacOS/Market, Resources/Market.icns, Info.plist}.
#   4. codesign with the stable Market identity.
#   5. verify, install to /Applications/Market.app, and remove stale backups.
#
# CLT-only: no xcodebuild. Outputs app/dist/Market.app and installs it.
set -e

HERE="${0:A:h}"                 # app/packaging
APP="${HERE:h}"                 # app
DIST="$APP/dist"
BUNDLE="$DIST/Market.app"
BIN="$APP/.build/release/Market"
ICNS="$HERE/Market.icns"
PLIST="$HERE/Info.plist"
INSTALL_DIR="/Applications"
INSTALLED_BUNDLE="$INSTALL_DIR/Market.app"
STAGED_BUNDLE="$INSTALL_DIR/.Market.app.installing.$$"
PREVIOUS_BUNDLE="$INSTALL_DIR/.Market.app.replacing.$$"

cleanup() {
  local exit_code=$?
  rm -rf "$STAGED_BUNDLE"
  if (( exit_code != 0 )) && [[ -d "$PREVIOUS_BUNDLE" ]]; then
    rm -rf "$INSTALLED_BUNDLE"
    mv "$PREVIOUS_BUNDLE" "$INSTALLED_BUNDLE"
  fi
  rm -rf "$PREVIOUS_BUNDLE"
  return $exit_code
}
trap cleanup EXIT INT TERM

echo "==> 1/5 build release binary"
"$APP/scripts/build.sh" release

[[ -f "$BIN" ]] || { echo "release binary not found at $BIN" >&2; exit 1; }

echo "==> 2/5 build icon"
if [[ ! -f "$ICNS" || "$HERE/icon.svg" -nt "$ICNS" ]]; then
  "$HERE/make-icon.sh"
else
  echo "icon up to date: $ICNS"
fi

echo "==> 3/5 assemble bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN"   "$BUNDLE/Contents/MacOS/Market"
cp "$ICNS"  "$BUNDLE/Contents/Resources/Market.icns"
cp "$PLIST" "$BUNDLE/Contents/Info.plist"
chmod +x "$BUNDLE/Contents/MacOS/Market"
# PkgInfo is optional but conventional for an APPL bundle.
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> 4/5 codesign"
# Stable self-signed identity (created 2026-07-02, keychain "Ivo Market Dev",
# key material in ~/Projects/Market/state/signing/): REQUIRED for UNUserNotificationCenter —
# usernoted silently refuses ad-hoc signatures, and ad-hoc cdhashes change every
# build, resetting notification permission. Fall back to ad-hoc only if missing.
if security find-identity -v -p codesigning | grep -q "Ivo Market Dev"; then
  codesign --force --deep --sign "Ivo Market Dev" "$BUNDLE"
else
  echo "WARNING: 'Ivo Market Dev' identity missing — ad-hoc signing (notifications will NOT register)"
  codesign --force --deep --sign - "$BUNDLE"
fi

echo "==> 5/5 verify and install"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist"

mkdir -p "$INSTALL_DIR"
rm -rf "$STAGED_BUNDLE" "$PREVIOUS_BUNDLE"
/usr/bin/ditto "$BUNDLE" "$STAGED_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$STAGED_BUNDLE"

# Stop the installed executable before replacing its bundle. The command is a
# no-op when Market is not running.
/usr/bin/pkill -x Market 2>/dev/null || true
if [[ -d "$INSTALLED_BUNDLE" ]]; then
  mv "$INSTALLED_BUNDLE" "$PREVIOUS_BUNDLE"
fi
mv "$STAGED_BUNDLE" "$INSTALLED_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$INSTALLED_BUNDLE"
/usr/bin/plutil -lint "$INSTALLED_BUNDLE/Contents/Info.plist"
rm -rf "$PREVIOUS_BUNDLE"

# Finder and Launch Services treat renamed bundles as independent applications.
# Remove every other bundle with Market's identifier, regardless of suffix,
# while leaving unrelated apps with similar names untouched.
for applications_dir in /Applications; do
  [[ -d "$applications_dir" ]] || continue
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$INSTALLED_BUNDLE" ]] && continue
    [[ -f "$candidate/Contents/Info.plist" ]] || continue
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$candidate/Contents/Info.plist" 2>/dev/null || true)
    [[ "$bundle_id" == "com.ivo.market" ]] || continue
    rm -rf "$candidate"
  done < <(find "$applications_dir" -mindepth 1 -maxdepth 1 -type d -print0)
done

echo
echo "built: $BUNDLE"
echo "installed: $INSTALLED_BUNDLE"
find "$BUNDLE" -type f | sort
