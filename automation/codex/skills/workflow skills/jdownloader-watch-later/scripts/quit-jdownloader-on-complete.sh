#!/usr/bin/env bash
set -euo pipefail

DOWNLOAD_ROOT="/Users/YOUR_USERNAME/Files/YouTube"
MARKER=""
IDLE_SECONDS=90
TIMEOUT_SECONDS=21600
LOG_FILE="/Users/YOUR_USERNAME/.memory/logs/jdownloader-watch-later/quit-on-complete.log"
READY_FILE=""
RUN_NONCE=""
POLL_SECONDS=10

usage() {
  cat <<'USAGE'
Usage:
  quit-jdownloader-on-complete.sh [options]

Options:
  --download-root PATH  Folder to watch. Default: /Users/YOUR_USERNAME/Files/YouTube
  --marker PATH         Marker file created before links were added.
  --idle-seconds N      Quit after this many idle seconds. Default: 90
  --timeout-seconds N   Give up after this many seconds. Default: 21600
  --log-file PATH       Log file path.
  --ready-file PATH     Optional private readiness record for the caller.
  --run-nonce VALUE     Caller nonce written into the readiness record.
  --poll-seconds N      Poll interval. Default: 10
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-root)
      DOWNLOAD_ROOT="${2:?Missing value for --download-root}"
      shift 2
      ;;
    --marker)
      MARKER="${2:?Missing value for --marker}"
      shift 2
      ;;
    --idle-seconds)
      IDLE_SECONDS="${2:?Missing value for --idle-seconds}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:?Missing value for --timeout-seconds}"
      shift 2
      ;;
    --log-file)
      LOG_FILE="${2:?Missing value for --log-file}"
      shift 2
      ;;
    --ready-file)
      READY_FILE="${2:?Missing value for --ready-file}"
      shift 2
      ;;
    --run-nonce)
      RUN_NONCE="${2:?Missing value for --run-nonce}"
      shift 2
      ;;
    --poll-seconds)
      POLL_SECONDS="${2:?Missing value for --poll-seconds}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$IDLE_SECONDS:$TIMEOUT_SECONDS:$POLL_SECONDS" in
  *[!0-9:]*|0:*|*:0:*|*:0)
    echo "idle, timeout, and poll seconds must be positive integers" >&2
    exit 2
    ;;
esac
if [[ -n "$READY_FILE" && -z "$RUN_NONCE" ]]; then
  echo "--ready-file requires --run-nonce" >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

count_recent_files() {
  local root="$1"
  local since_epoch="$2"
  find "$root" \
    -type f -print 2>/dev/null |
    while IFS= read -r file; do
      modified="$(stat -f %m "$file" 2>/dev/null || echo 0)"
      if [[ "$modified" -ge "$since_epoch" ]]; then
        printf '%s\n' "$file"
      fi
    done |
    wc -l | tr -d ' '
}

if [[ -z "$MARKER" || ! -f "$MARKER" ]]; then
  MARKER="$(mktemp "/tmp/jd-quit-marker.XXXXXX")"
  touch "$MARKER"
fi

cleanup() {
  if [[ -n "$READY_FILE" ]]; then
    rm -f "$READY_FILE"
  fi
  rm -f "$MARKER"
}
trap cleanup EXIT

if [[ -n "$READY_FILE" ]]; then
  mkdir -p "$(dirname "$READY_FILE")"
  ready_tmp="$(mktemp "$(dirname "$READY_FILE")/.watcher-ready.XXXXXX")"
  printf '{"pid":%d,"run_nonce":"%s","ready_at":"%s"}\n' \
    "$$" "$RUN_NONCE" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$ready_tmp"
  chmod 600 "$ready_tmp"
  mv "$ready_tmp" "$READY_FILE"
fi

start_epoch="$(date +%s)"
marker_epoch="$(stat -f %m "$MARKER" 2>/dev/null || date +%s)"
saw_activity=0
last_activity_epoch="$start_epoch"

log "watch start root=$DOWNLOAD_ROOT marker=$MARKER idle=${IDLE_SECONDS}s timeout=${TIMEOUT_SECONDS}s"

while :; do
  now="$(date +%s)"
  elapsed=$((now - start_epoch))

  if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
    log "timeout reached; leaving JDownloader open"
    exit 0
  fi

  if ! pgrep -f '/Applications/JDownloader 2/JDownloader2.app' >/dev/null 2>&1; then
    log "JDownloader already stopped"
    exit 0
  fi

  if [[ ! -d "$DOWNLOAD_ROOT" ]]; then
    sleep "$POLL_SECONDS"
    continue
  fi

  temp_count="$(
    find "$DOWNLOAD_ROOT" \
      -type f \( -iname '*.part' -o -iname '*.jdtmp' -o -iname '*.tmp' \) \
      -print 2>/dev/null | wc -l | tr -d ' '
  )"

  newer_count="$(
    count_recent_files "$DOWNLOAD_ROOT" "$marker_epoch"
  )"

  recent_since=$((now - IDLE_SECONDS))
  recent_count="$(
    count_recent_files "$DOWNLOAD_ROOT" "$recent_since"
  )"

  if [[ "$temp_count" -gt 0 || "$newer_count" -gt 0 || "$recent_count" -gt 0 ]]; then
    saw_activity=1
  fi

  if [[ "$temp_count" -gt 0 || "$recent_count" -gt 0 ]]; then
    last_activity_epoch="$now"
  fi

  idle_for=$((now - last_activity_epoch))
  if [[ "$saw_activity" -eq 1 && "$temp_count" -eq 0 && "$idle_for" -ge "$IDLE_SECONDS" ]]; then
    log "idle complete; quitting JDownloader"
    osascript -e 'tell application "JDownloader2" to quit' >/dev/null 2>&1 || true
    sleep "$POLL_SECONDS"
    if pgrep -f '/Applications/JDownloader 2/JDownloader2.app' >/dev/null 2>&1; then
      log "graceful quit did not stop app; leaving it open"
      exit 1
    fi
    log "JDownloader quit"
    exit 0
  fi

  sleep "$POLL_SECONDS"
done
