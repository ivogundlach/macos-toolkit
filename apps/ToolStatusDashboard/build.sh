#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Tool Dashboard.app"
BIN="$BUILD/ToolStatusDashboard"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"

# The model API rejects an output schema outside its strict structured-output
# subset with a 400, before the repair agent runs at all. That failure is
# server-side and looks exactly like an ordinary unsuccessful repair, so a
# `{"const": 5}` property shipped on 2026-08-04 and silently made every repair a
# no-op for three days. Refuse to deploy a schema that would be rejected.
python3 - "$ROOT" <<'VALIDATE_SCHEMAS' || exit 1
import importlib.util, json, sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("w", root / "scripts/tool-status-repair-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
problems = []
for name in ("tool-status-repair-result.schema.json", "tool-status-repair-decision.schema.json"):
    path = root / "scripts" / name
    try:
        schema = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        problems.append(f"{name}: unreadable ({error})")
        continue
    problems.extend(f"{name}: {issue}" for issue in worker.structured_output_schema_errors(schema))
if problems:
    print("Refusing to build: the model API would reject these repair schemas,")
    print("which would make every repair a silent no-op:")
    for problem in problems:
        print(f"  - {problem}")
    raise SystemExit(1)
print("Repair output schemas conform to the API structured-output subset.")
VALIDATE_SCHEMAS

rm -rf "$APP" "$BIN" "$BUILD/render-preview" \
  "$BUILD/Tool Status Dashboard.app" \
  "$BUILD/Tool Status Dashboard Notifier.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library \
  -sdk "$SDK" \
  -target "$TARGET" \
  "$ROOT/Sources/ToolStatusDashboard.swift" \
  "$ROOT/Sources/RefractiveGlass.swift" \
  -o "$BIN"

cp "$BIN" "$APP/Contents/MacOS/ToolStatusDashboard"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/scripts/tool-status-scan.py" "$APP/Contents/Resources/tool-status-scan.py"
cp "$ROOT/scripts/gws-auth-login.py" "$APP/Contents/Resources/gws-auth-login.py"
cp "$ROOT/scripts/canvas-auth-login.py" "$APP/Contents/Resources/canvas-auth-login.py"
cp "$ROOT/scripts/launchagent-enable.py" "$APP/Contents/Resources/launchagent-enable.py"
cp "$ROOT/scripts/tool-status-background-scan.py" "$APP/Contents/Resources/tool-status-background-scan.py"
cp "$ROOT/scripts/tool-status-repair-worker.py" "$APP/Contents/Resources/tool-status-repair-worker.py"
cp "$ROOT/scripts/tool-status-repair-result.schema.json" "$APP/Contents/Resources/tool-status-repair-result.schema.json"
cp "$ROOT/scripts/tool-status-repair-decision.schema.json" "$APP/Contents/Resources/tool-status-repair-decision.schema.json"

# App icon: regenerate the .icns from SVG if the source is newer (or the .icns is missing), then bundle it.
if [ ! -f "$ROOT/Icon/AppIcon.icns" ] || [ "$ROOT/Icon/AppIcon.svg" -nt "$ROOT/Icon/AppIcon.icns" ]; then
  "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/ToolStatusDashboard" \
  "$APP/Contents/Resources/tool-status-scan.py" \
  "$APP/Contents/Resources/gws-auth-login.py" \
  "$APP/Contents/Resources/canvas-auth-login.py" \
  "$APP/Contents/Resources/launchagent-enable.py" \
  "$APP/Contents/Resources/tool-status-background-scan.py" \
  "$APP/Contents/Resources/tool-status-repair-worker.py"

if [[ "${NO_DEPLOY:-0}" == "1" ]]; then
  echo "Built without signing or installing: $APP"
  exit 0
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Ivo Market Dev}"
codesign --force --sign "$SIGNING_IDENTITY" "$APP" >/dev/null
# Verify the newly signed bundle in its canonical installed location before
# removing the obsolete pre-rename bundle.
rm -rf "/Applications/Tool Dashboard.app"
cp -R "$APP" "/Applications/Tool Dashboard.app"
codesign --verify --strict --verbose=4 "/Applications/Tool Dashboard.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "/Applications/Tool Status Dashboard.app/Contents/Helpers/Tool Status Dashboard Notifier.app" \
  >/dev/null 2>&1 || true
if [ -d "/Applications/Tool Status Dashboard Notifier.app" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "/Applications/Tool Status Dashboard Notifier.app" >/dev/null 2>&1 || true
  rm -rf "/Applications/Tool Status Dashboard Notifier.app"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "/Applications/Tool Status Dashboard.app" >/dev/null 2>&1 || true
rm -rf "/Applications/Tool Status Dashboard.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/Tool Dashboard.app"

mkdir -p "$HOME/.local/bin" "$HOME/.local/state/tool-status-dashboard" "$HOME/Library/LaunchAgents"
DEPLOYMENT_MARKER="$HOME/.local/state/tool-status-dashboard/deployment-in-progress.json"
printf '{"pid":%d,"startedAt":"%s"}\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$DEPLOYMENT_MARKER.tmp"
chmod 600 "$DEPLOYMENT_MARKER.tmp"
mv "$DEPLOYMENT_MARKER.tmp" "$DEPLOYMENT_MARKER"
cleanup_deployment_marker() { rm -f "$DEPLOYMENT_MARKER" "$DEPLOYMENT_MARKER.tmp"; }
trap cleanup_deployment_marker EXIT
install -m 755 "$ROOT/scripts/tool-status-background-scan-wrapper.sh" "$HOME/.local/bin/tool-status-background-scan"
install -m 755 "$ROOT/scripts/tool-status-repair-worker-wrapper.sh" "$HOME/.local/bin/tool-status-repair-worker"
install -m 755 "$ROOT/scripts/tool-status-register" "$HOME/.local/bin/tool-status-register"
install -m 755 "$ROOT/scripts/tool-status-notify.py" "$HOME/.local/bin/tool-status-notify"
install -m 644 "$ROOT/LaunchAgents/com.ivogundlach.tool-status-dashboard.scan.plist" \
  "$HOME/Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.scan.plist"
install -m 644 "$ROOT/LaunchAgents/com.ivogundlach.tool-status-dashboard.repair.plist" \
  "$HOME/Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.repair.plist"
launchctl bootout "gui/$(id -u)/com.ivogundlach.tool-status-dashboard.scan" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.scan.plist"
if [[ "${TOOL_STATUS_REPAIR_SELF_DEPLOY:-0}" != "1" ]]; then
  launchctl bootout "gui/$(id -u)/com.ivogundlach.tool-status-dashboard.repair" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.repair.plist"
elif ! launchctl print "gui/$(id -u)/com.ivogundlach.tool-status-dashboard.repair" >/dev/null 2>&1; then
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ivogundlach.tool-status-dashboard.repair.plist"
fi

cleanup_deployment_marker
trap - EXIT
echo "Built and installed: /Applications/Tool Dashboard.app"
