#!/bin/bash
# SOURCE OF TRUTH. build.sh copies this file into
# "/Applications/Tool Dashboard.app" (or ~/.local/bin). The deployed copy is a
# build artifact: edit THIS file, then run Projects/ToolStatusDashboard/build.sh.
# Editing the deployed copy, or editing here without rebuilding, makes the dashboard
# report stale findings. The "Deployed source drift" check flags that divergence.
set -u

STATE="$HOME/.local/state/tool-status-dashboard"
RUNNER="/Applications/Tool Dashboard.app/Contents/Resources/tool-status-background-scan.py"
ERRORS="$STATE/errors.log"
mkdir -p "$STATE"

if [[ ! -x "$RUNNER" ]]; then
  printf '%s\n' '{"cause":"The installed background scanner is missing or not executable."}' > "$STATE/wrapper-failure.json.tmp"
  mv "$STATE/wrapper-failure.json.tmp" "$STATE/wrapper-failure.json"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "installed scanner missing: $RUNNER" >> "$ERRORS"
  exit 127
fi

"$RUNNER" >> "$STATE/background-scan.out" 2>> "$ERRORS"
status=$?
if [[ $status -ne 0 ]]; then
  printf '{"cause":"The previous Tool Dashboard background run exited %d. The scan or incident-queue step failed; full details are in the error and decision logs."}\n' "$status" > "$STATE/wrapper-failure.json.tmp"
  mv "$STATE/wrapper-failure.json.tmp" "$STATE/wrapper-failure.json"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "background scanner exited $status" >> "$ERRORS"
fi
exit "$status"
