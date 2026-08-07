#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Vitals.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"
HELPER_LABEL="com.ivogundlach.vitals.helper"
FINDINGS_LABEL="com.ivogundlach.vitals.findings"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Library/PrivilegedHelperTools" \
         "$APP/Contents/Library/LaunchDaemons"

# The app: every source except the privileged helper, which is its own binary so
# root never executes the full SwiftUI app.
# macOS ships bash 3.2, which has no `mapfile`.
APP_SOURCES=()
while IFS= read -r source_file; do
  APP_SOURCES+=("$source_file")
done < <(find "$ROOT/Sources" -name '*.swift' -not -path '*/HelperDaemon/*' | sort)

echo "Compiling Vitals (${#APP_SOURCES[@]} sources)..."
# No -parse-as-library: Sources/main.swift uses top-level code to branch into
# headless daemon mode before SwiftUI starts.
xcrun swiftc \
  -swift-version 5 \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  "${APP_SOURCES[@]}" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement \
  -lsqlite3 \
  -o "$BUILD/Vitals"

echo "Compiling privileged helper..."
xcrun swiftc \
  -swift-version 5 \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  "$ROOT/Sources/HelperDaemon/main.swift" \
  -o "$BUILD/$HELPER_LABEL"

cp "$BUILD/Vitals" "$APP/Contents/MacOS/Vitals"
cp "$BUILD/$HELPER_LABEL" "$APP/Contents/Library/PrivilegedHelperTools/$HELPER_LABEL"
cp "$ROOT/LaunchAgents/$HELPER_LABEL.plist" "$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Regenerate the .icns from the SVG when the source is newer (or the .icns is missing).
if [ -f "$ROOT/Icon/AppIcon.svg" ]; then
  if [ ! -f "$ROOT/Icon/AppIcon.icns" ] || [ "$ROOT/Icon/AppIcon.svg" -nt "$ROOT/Icon/AppIcon.icns" ]; then
    "$ROOT/scripts/make-icon.sh"
  fi
fi
if [ -f "$ROOT/Icon/AppIcon.icns" ]; then
  cp "$ROOT/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

chmod +x "$APP/Contents/MacOS/Vitals" \
         "$APP/Contents/Library/PrivilegedHelperTools/$HELPER_LABEL"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ "${NO_DEPLOY:-0}" == "1" ]]; then
  echo "Built without signing or installing: $APP"
  exit 0
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Ivo Market Dev}"
# Sign the helper before the app so the outer signature covers a stable payload.
codesign --force --sign "$SIGNING_IDENTITY" \
  "$APP/Contents/Library/PrivilegedHelperTools/$HELPER_LABEL" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$APP" >/dev/null

# Stop the background recorder before touching the bundle it runs from. Its
# LaunchAgent is KeepAlive, so killing it below would have launchd respawn it
# straight into a half-copied binary — AMFI then kills that for an invalid
# signature, which logs a spurious "Launch Constraint Violation" crash report on
# every single build. Booting the job out first removes the race entirely.
SAMPLER_LABEL="com.ivogundlach.vitals.sampler"
SAMPLER_PLIST="$HOME/Library/LaunchAgents/$SAMPLER_LABEL.plist"
SAMPLER_DOMAIN="gui/$(id -u)"
SAMPLER_WAS_LOADED=0
if launchctl print "$SAMPLER_DOMAIN/$SAMPLER_LABEL" >/dev/null 2>&1; then
  SAMPLER_WAS_LOADED=1
  launchctl bootout "$SAMPLER_DOMAIN/$SAMPLER_LABEL" >/dev/null 2>&1 || true
fi

# Replace the running copy in place; leaving suffixed .app bundles behind would
# register them with Launch Services as separate applications.
if pgrep -x Vitals >/dev/null 2>&1; then
  osascript -e 'tell application "Vitals" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Vitals 2>/dev/null || true
fi

rm -rf "/Applications/Vitals.app"
cp -R "$APP" "/Applications/Vitals.app"
codesign --verify --strict --verbose=2 "/Applications/Vitals.app"

# Install one stable synthesis command and one calendar trigger. The command
# owns the every-other-day gate, so launchd can remain a simple daily 04:00
# wake/catch-up mechanism.
install -m 755 "$ROOT/scripts/vitals-findings" "$HOME/.local/bin/vitals-findings"
mkdir -p "$HOME/.local/state/vitals/findings"
chmod 700 "$HOME/.local/state/vitals" "$HOME/.local/state/vitals/findings" 2>/dev/null || true
"$HOME/.local/bin/vitals-findings" --initialize
FINDINGS_PLIST="$HOME/Library/LaunchAgents/$FINDINGS_LABEL.plist"
cp "$ROOT/LaunchAgents/$FINDINGS_LABEL.plist" "$FINDINGS_PLIST"
plutil -lint "$FINDINGS_PLIST" >/dev/null
launchctl bootout "$SAMPLER_DOMAIN/$FINDINGS_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "$SAMPLER_DOMAIN" "$FINDINGS_PLIST"
if command -v tool-status-register >/dev/null 2>&1; then
  tool-status-register add vitals-findings --name "Vitals Findings" --check help >/dev/null
fi

# Back up only if it was running before: building must not silently enable a
# recorder the user had turned off.
if [[ "$SAMPLER_WAS_LOADED" == "1" && -f "$SAMPLER_PLIST" ]]; then
  launchctl bootstrap "$SAMPLER_DOMAIN" "$SAMPLER_PLIST" >/dev/null 2>&1 \
    || echo "warning: could not restart $SAMPLER_LABEL; re-enable it in Settings → Recording"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/Vitals.app"

echo "Built and installed: /Applications/Vitals.app"
