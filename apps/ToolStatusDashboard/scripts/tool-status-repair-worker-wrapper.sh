#!/bin/bash
# SOURCE OF TRUTH. build.sh copies this file into
# "/Applications/Tool Dashboard.app" (or ~/.local/bin). The deployed copy is a
# build artifact: edit THIS file, then run Projects/ToolStatusDashboard/build.sh.
# Editing the deployed copy, or editing here without rebuilding, makes the dashboard
# report stale findings. The "Deployed source drift" check flags that divergence.
set -u

STATE="$HOME/.local/state/tool-status-dashboard"
WORKER="/Applications/Tool Dashboard.app/Contents/Resources/tool-status-repair-worker.py"
ERRORS="$STATE/repair-worker-errors.log"
mkdir -p "$STATE"

if [[ ! -x "$WORKER" ]]; then
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "installed repair worker missing: $WORKER" >> "$ERRORS"
  exit 127
fi

"$WORKER" >> "$STATE/repair-worker.out" 2>> "$ERRORS"
status=$?
if [[ $status -ne 0 ]]; then
  printf '%s repair worker exited %d\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$status" >> "$ERRORS"
fi
exit "$status"
