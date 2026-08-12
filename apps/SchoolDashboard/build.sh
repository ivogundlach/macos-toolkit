#!/usr/bin/env bash
# Builds and installs /Applications/School.app.
#
#   ./build.sh              build, sign, install
#   NO_DEPLOY=1 ./build.sh  build only
#
# Signed with the personal "Ivo Market Dev" identity so TCC grants (Apple Events
# for the Canvas re-login button) survive a rebuild instead of being re-prompted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/School.app"
BIN="$BUILD/SchoolDashboard"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"

rm -rf "$APP" "$BIN"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  "$ROOT/Sources/App.swift" \
  "$ROOT/Sources/Shell.swift" \
  "$ROOT/Sources/Model.swift" \
  "$ROOT/Sources/Theme.swift" \
  "$ROOT/Sources/OverviewView.swift" \
  "$ROOT/Sources/AssignmentsView.swift" \
  "$ROOT/Sources/ScheduleView.swift" \
  "$ROOT/Sources/CoursesView.swift" \
  "$ROOT/Sources/GradesView.swift" \
  "$ROOT/Sources/StatusView.swift" \
  "$ROOT/Sources/RefractiveGlass.swift" \
  -o "$BIN"

cp "$BIN" "$APP/Contents/MacOS/SchoolDashboard"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/SchoolDashboard"

if [ -f "$ROOT/Icon/AppIcon.svg" ]; then
  if [ ! -f "$ROOT/Icon/AppIcon.icns" ] || [ "$ROOT/Icon/AppIcon.svg" -nt "$ROOT/Icon/AppIcon.icns" ]; then
    "$ROOT/scripts/make-icon.sh"
  fi
  cp "$ROOT/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

if [[ "${NO_DEPLOY:-0}" == "1" ]]; then
  echo "Built without signing or installing: $APP"
  exit 0
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Ivo Market Dev}"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP" >/dev/null

rm -rf "/Applications/School.app"
cp -R "$APP" "/Applications/School.app"
codesign --verify --strict "/Applications/School.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/School.app"

echo "Built and installed: /Applications/School.app"
