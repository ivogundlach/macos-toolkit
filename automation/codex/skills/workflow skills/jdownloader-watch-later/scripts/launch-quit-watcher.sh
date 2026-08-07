#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
STATE_DIR=""
WATCHER=""
DOWNLOAD_ROOT=""
MARKER=""
READY_TIMEOUT_TENTHS=25
UUIDGEN="${JDOWNLOADER_UUIDGEN:-/usr/bin/uuidgen}"

if [[ "${1:-}" == "--run-job" ]]; then
  label="${2:?Missing launchd label}"
  shift 2
  status=0
  "$@" || status=$?
  /bin/launchctl remove "$label" >/dev/null 2>&1 || true
  exit "$status"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) STATE_DIR="${2:?Missing value for --state-dir}"; shift 2 ;;
    --watcher) WATCHER="${2:?Missing value for --watcher}"; shift 2 ;;
    --download-root) DOWNLOAD_ROOT="${2:?Missing value for --download-root}"; shift 2 ;;
    --marker) MARKER="${2:?Missing value for --marker}"; shift 2 ;;
    --ready-timeout-tenths) READY_TIMEOUT_TENTHS="${2:?Missing value for --ready-timeout-tenths}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$STATE_DIR" || -z "$WATCHER" || -z "$DOWNLOAD_ROOT" || -z "$MARKER" ]]; then
  echo "--state-dir, --watcher, --download-root, and --marker are required" >&2
  exit 2
fi
if [[ ! -x "$WATCHER" || ! -x "$UUIDGEN" ]]; then
  exit 1
fi
case "$READY_TIMEOUT_TENTHS" in
  ''|*[!0-9]*|0) echo "--ready-timeout-tenths must be a positive integer" >&2; exit 2 ;;
esac

nonce="$($UUIDGEN)"
label="com.ivogundlach.jdownloader-watch-later.$nonce"
ready_file="$STATE_DIR/watcher-ready-$nonce.json"

/bin/launchctl submit -l "$label" -- "$0" --run-job "$label" \
  "$WATCHER" \
  --download-root "$DOWNLOAD_ROOT" \
  --marker "$MARKER" \
  --ready-file "$ready_file" \
  --run-nonce "$nonce"

for ((attempt = 0; attempt < READY_TIMEOUT_TENTHS; attempt++)); do
  if [[ -s "$ready_file" ]]; then
    ready_nonce="$(/usr/bin/jq -r '.run_nonce // empty' "$ready_file" 2>/dev/null || true)"
    ready_pid="$(/usr/bin/jq -r '.pid // empty' "$ready_file" 2>/dev/null || true)"
    case "$ready_pid" in
      ''|*[!0-9]*) ;;
      *)
        if [[ "$ready_nonce" == "$nonce" ]] && /bin/kill -0 "$ready_pid" 2>/dev/null; then
          exit 0
        fi
        ;;
    esac
  fi
  /bin/sleep 0.1
done

/bin/launchctl remove "$label" >/dev/null 2>&1 || true
/bin/rm -f "$ready_file"
exit 1
