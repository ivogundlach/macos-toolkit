#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SDK="$(xcrun --show-sdk-path)"

swiftc -parse-as-library -D IVO_LOGIC_TEST \
  -sdk "$SDK" -target arm64-apple-macosx26.0 \
  "$ROOT/Sources/ToolStatusDashboard.swift" \
  "$ROOT/Sources/RefractiveGlass.swift" \
  "$ROOT/scripts/test-repair-ui-state.swift" \
  -o "$TMP/test-repair-ui-state"
"$TMP/test-repair-ui-state"

SOURCE="$ROOT/Sources/ToolStatusDashboard.swift"
rg -q 'Button\("Approve"\)' "$SOURCE"
rg -q 'Button\("Add Thoughts"\)' "$SOURCE"
rg -q '"Stop Repair" : "Dismiss"' "$SOURCE"
rg -q 'url\(forResource: "tool-status-background-scan", withExtension: "py"\)' "$SOURCE"
rg -q 'guard let payload = Self\.loadCachedPayload\(\)' "$SOURCE"
! rg -q 'Approve full repair|Send feedback|Not now' "$SOURCE"
printf '%s\n' 'repair UI labels passed (Approve, Add Thoughts, Dismiss, Stop Repair)'
