#!/bin/bash
# SOURCE OF TRUTH. build.sh copies this file into
# "/Applications/Tool Dashboard.app" (or ~/.local/bin). The deployed copy is a
# build artifact: edit THIS file, then run Projects/ToolStatusDashboard/build.sh.
# Editing the deployed copy, or editing here without rebuilding, makes the dashboard
# report stale findings. The "Deployed source drift" check flags that divergence.
set -u

STATE="${TOOL_STATUS_STATE:-$HOME/.local/state/tool-status-dashboard}"
RUNNER="${TOOL_STATUS_BACKGROUND_RUNNER:-/Applications/Tool Dashboard.app/Contents/Resources/tool-status-background-scan.py}"
ERRORS="$STATE/errors.log"
DEPLOYMENT_MARKER="$STATE/deployment-in-progress.json"
DEPLOYMENT_MARKER_MAX_AGE=600
mkdir -p "$STATE"

deployment_marker_fresh() {
  [[ -f "$DEPLOYMENT_MARKER" ]] || return 1
  marker_mtime="$(stat -f '%m' "$DEPLOYMENT_MARKER" 2>/dev/null || echo 0)"
  now_epoch="$(date '+%s')"
  marker_age=$((now_epoch - marker_mtime))
  [[ $marker_age -ge 0 && $marker_age -le $DEPLOYMENT_MARKER_MAX_AGE ]]
}

if [[ ! -x "$RUNNER" ]]; then
  printf '%s\n' '{"cause":"The installed background scanner is missing or not executable."}' > "$STATE/wrapper-failure.json.tmp"
  mv "$STATE/wrapper-failure.json.tmp" "$STATE/wrapper-failure.json"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "installed scanner missing: $RUNNER" >> "$ERRORS"
  exit 127
fi

"$RUNNER" "$@" >> "$STATE/background-scan.out" 2>> "$ERRORS"
status=$?
if [[ $status -ne 0 ]]; then
  # build.sh writes this marker before replacing the LaunchAgent. launchd then
  # terminates the old scanner process by design; recording that SIGTERM as a
  # fresh scanner incident creates a false failure after every successful deploy.
  # Outside a fresh deployment marker the same signal remains a real failure.
  if [[ $status -ge 128 ]] && deployment_marker_fresh; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "background scanner interrupted during declared deployment (exit $status)" >> "$ERRORS"
    exit 0
  fi
  printf '{"cause":"The previous Tool Dashboard background run exited %d. The scan or incident-queue step failed; full details are in the error and decision logs."}\n' "$status" > "$STATE/wrapper-failure.json.tmp"
  mv "$STATE/wrapper-failure.json.tmp" "$STATE/wrapper-failure.json"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "background scanner exited $status" >> "$ERRORS"
fi
exit "$status"
