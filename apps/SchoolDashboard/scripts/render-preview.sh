#!/usr/bin/env bash
# Render every tab to a PNG offscreen. No window, no Dock icon, no focus change.
#   ./scripts/render-preview.sh [light|dark]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-dark}"
OUT="$ROOT/build/preview"
BIN="$ROOT/build/render-preview"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "$ROOT/build"
swiftc -parse-as-library \
  -sdk "$SDK" -target arm64-apple-macosx26.0 \
  "$ROOT/scripts/RenderPreview.swift" \
  "$ROOT/Sources/Model.swift" \
  "$ROOT/Sources/Theme.swift" \
  "$ROOT/Sources/OverviewView.swift" \
  "$ROOT/Sources/AssignmentsView.swift" \
  "$ROOT/Sources/ScheduleView.swift" \
  "$ROOT/Sources/CoursesView.swift" \
  "$ROOT/Sources/GradesView.swift" \
  "$ROOT/Sources/StatusView.swift" \
  "$ROOT/Sources/RefractiveGlass.swift" \
  "$ROOT/Sources/Shell.swift" \
  -o "$BIN"

"$BIN" "$MODE" "$OUT"
