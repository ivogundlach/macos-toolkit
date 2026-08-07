#!/usr/bin/env bash
set -euo pipefail

PLAYLIST_URL="https://www.youtube.com/playlist?list=WL"
BROWSER=""
BROWSER_EXPLICIT=0
NO_BROWSER_COOKIES=0
JD_HOME="/Applications/JDownloader 2"
WATCH_DIR=""
STATE_DIR="${JDOWNLOADER_STATE_DIR:-/Users/YOUR_USERNAME/.local/state/jdownloader-watch-later}"
STATE_FILE=""
DRY_RUN=0
ADD_ALL=0
AUTO_START="TRUE"
QUIT_ON_COMPLETE=1
DOWNLOAD_DIR=""
METHOD="auto"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENUMERATOR="${JDOWNLOADER_PLAYLIST_ENUMERATOR:-$SCRIPT_DIR/enumerate-youtube-playlist.py}"
QUIT_WATCHER="${JDOWNLOADER_QUIT_WATCHER:-$SCRIPT_DIR/quit-jdownloader-on-complete.sh}"
WATCHER_LAUNCHER="${JDOWNLOADER_WATCHER_LAUNCHER:-$SCRIPT_DIR/launch-quit-watcher.sh}"

usage() {
  cat <<'USAGE'
Usage:
  watch-later-to-jdownloader.sh [options]

Options:
  --browser VALUE        Strict cookie browser: safari or firefox.
                         Default: Safari, then Firefox.
  --no-browser-cookies   Explicit opt-out; Watch Later then cannot proceed.
  --watch-dir PATH       JDownloader Folder Watch directory.
                         Default: <JD home>/cfg/folderwatch
  --playlist-url URL     Playlist URL. Default: YouTube Watch Later
  --download-dir PATH    Optional JDownloader download folder for these links.
  --method VALUE         auto, cnl, or folderwatch. Default: auto
  --all                  Re-send all currently visible Watch Later links.
  --dry-run              Print what would be sent. Do not write a crawljob.
  --no-autostart         Add to JDownloader but do not auto-start downloads.
  --keep-open            Do not quit JDownloader after downloads complete.
  --quit-on-complete     Quit JDownloader after downloads complete. Default.
  -h, --help             Show this help.

Environment overrides:
  YT_DLP_BROWSER
  JDOWNLOADER_HOME
  JDOWNLOADER_FOLDERWATCH_DIR
  JDOWNLOADER_STATE_DIR
  JDOWNLOADER_PLAYLIST_ENUMERATOR
  JDOWNLOADER_QUIT_WATCHER
  JDOWNLOADER_WATCHER_LAUNCHER
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser)
      BROWSER="${2:?Missing value for --browser}"
      BROWSER_EXPLICIT=1
      shift 2
      ;;
    --no-browser-cookies)
      NO_BROWSER_COOKIES=1
      shift
      ;;
    --watch-dir)
      WATCH_DIR="${2:?Missing value for --watch-dir}"
      shift 2
      ;;
    --playlist-url)
      PLAYLIST_URL="${2:?Missing value for --playlist-url}"
      shift 2
      ;;
    --download-dir)
      DOWNLOAD_DIR="${2:?Missing value for --download-dir}"
      shift 2
      ;;
    --method)
      METHOD="${2:?Missing value for --method}"
      case "$METHOD" in
        auto|cnl|folderwatch) ;;
        *)
          echo "Invalid --method: $METHOD" >&2
          echo "Use: auto, cnl, or folderwatch" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --all)
      ADD_ALL=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-autostart)
      AUTO_START="FALSE"
      shift
      ;;
    --keep-open)
      QUIT_ON_COMPLETE=0
      shift
      ;;
    --quit-on-complete)
      QUIT_ON_COMPLETE=1
      shift
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

if [[ "$BROWSER_EXPLICIT" -eq 0 && -n "${YT_DLP_BROWSER:-}" ]]; then
  BROWSER="$YT_DLP_BROWSER"
  BROWSER_EXPLICIT=1
fi
if [[ "$BROWSER_EXPLICIT" -eq 1 ]]; then
  case "$BROWSER" in
    safari|firefox) ;;
    *)
      echo "Unsupported browser '$BROWSER'. Remove the override or use safari/firefox; Chrome cookie profiles are retired." >&2
      exit 2
      ;;
  esac
fi
JD_HOME="${JDOWNLOADER_HOME:-$JD_HOME}"
WATCH_DIR="${JDOWNLOADER_FOLDERWATCH_DIR:-${WATCH_DIR:-$JD_HOME/cfg/folderwatch}}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/sent-watch-later-urls.txt}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need jq
need comm
need sort
need python3
need curl

if [[ ! -x "$ENUMERATOR" ]]; then
  echo "Playlist enumerator missing or not executable: $ENUMERATOR" >&2
  exit 1
fi

download_root="${DOWNLOAD_DIR:-/Users/YOUR_USERNAME/Files/YouTube}"

start_quit_watcher() {
  if [[ "$QUIT_ON_COMPLETE" -ne 1 ]]; then
    return 0
  fi

  local marker="$1"
  local watcher="$QUIT_WATCHER"
  if [[ ! -x "$watcher" ]]; then
    echo "PARTIAL: links were submitted, but automatic quitting is disabled because the watcher is missing or not executable: $watcher" >&2
    echo "Quit JDownloader manually after the downloads finish, then repair the watcher before the next run." >&2
    return 1
  fi

  if [[ ! -x "$WATCHER_LAUNCHER" ]]; then
    echo "PARTIAL: links were submitted, but automatic quitting is disabled because the persistent watcher launcher is missing or not executable: $WATCHER_LAUNCHER" >&2
    echo "Quit JDownloader manually after the downloads finish, then repair the watcher launcher before the next run." >&2
    return 1
  fi

  if "$WATCHER_LAUNCHER" --state-dir "$STATE_DIR" --watcher "$watcher" \
    --download-root "$download_root" --marker "$marker"; then
    run_marker=""
    echo "JDownloader will quit after downloads complete." >&2
    return 0
  fi

  echo "PARTIAL: links were submitted, but the quit-on-complete watcher did not become ready." >&2
  echo "Quit JDownloader manually after downloads finish. Inspect the watcher log before retrying." >&2
  return 1
}

all_urls="$(mktemp)"
sorted_state="$(mktemp)"
new_urls="$(mktemp)"
enumeration_json="$(mktemp)"
job_tmp=""
run_marker=""
trap 'rm -f "$all_urls" "$sorted_state" "$new_urls" "$enumeration_json" ${job_tmp:+"$job_tmp"} ${run_marker:+"$run_marker"}' EXIT

enumerator_args=(--source "$PLAYLIST_URL" --mode auth)
if [[ "$BROWSER_EXPLICIT" -eq 1 ]]; then
  enumerator_args+=(--browser "$BROWSER")
fi
if [[ "$NO_BROWSER_COOKIES" -eq 1 ]]; then
  enumerator_args+=(--no-browser-cookies)
fi
set +e
python3 "$ENUMERATOR" "${enumerator_args[@]}" > "$enumeration_json"
enumeration_rc=$?
set -e
if [[ "$enumeration_rc" -ne 0 ]]; then
  jq '.' "$enumeration_json" >&2 2>/dev/null || echo "Watch Later enumeration failed without structured output." >&2
  exit 1
fi
jq -r '.result.urls[]?' "$enumeration_json" | sort -u > "$all_urls"
if [[ "$(jq -r '.status' "$enumeration_json")" == "partial" ]]; then
  echo "Watch Later enumeration continued with degradations:" >&2
  jq -c '.degradation_reasons' "$enumeration_json" >&2
fi

if [[ ! -s "$all_urls" ]]; then
  if [[ "$(jq -r '.result.entry_count // -1' "$enumeration_json")" -eq 0 ]]; then
    echo "YouTube returned Watch Later as empty. Nothing to send to JDownloader." >&2
    exit 0
  fi
  cat >&2 <<EOF
No Watch Later URLs were found.
Most likely causes:
- You are not logged into YouTube in the selected browser.
- The selected browser cookies cannot be read.
- YouTube temporarily blocked or changed private playlist access.

Try:
  $0 --browser safari
  $0 --browser firefox
EOF
  exit 1
fi

if [[ "$ADD_ALL" -eq 1 ]]; then
  cp "$all_urls" "$new_urls"
else
  if [[ -f "$STATE_FILE" ]]; then
    sort -u "$STATE_FILE" > "$sorted_state"
  else
    : > "$sorted_state"
  fi
  comm -23 "$all_urls" "$sorted_state" > "$new_urls"
fi

total_count="$(wc -l < "$all_urls" | tr -d ' ')"
new_count="$(wc -l < "$new_urls" | tr -d ' ')"

if [[ "$new_count" -eq 0 ]]; then
  echo "Found $total_count Watch Later URLs. No new URLs to send to JDownloader." >&2
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  cnl_available=0
  if [[ "$METHOD" == "auto" || "$METHOD" == "cnl" ]] &&
    curl -fsS --max-time 3 http://127.0.0.1:9666/flash/ >/dev/null 2>&1; then
    cnl_available=1
  fi
  if [[ "$METHOD" == "cnl" || ("$METHOD" == "auto" && "$cnl_available" -eq 1) ]]; then
    method_label="Click'n'Load"
  else
    method_label="Folder Watch"
  fi
  echo "Found $total_count Watch Later URLs. Would send $new_count URLs via $method_label." >&2
  jq -c '{network_performed,authenticated_read_performed,browser_path,attempts,degradation_reasons}' "$enumeration_json" >&2
  cat "$new_urls"
  exit 0
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

package_name="YouTube Watch Later $(date '+%Y-%m-%d %H:%M')"

atomic_jq_update() {
  local target="$1" filter="$2" temporary mode
  temporary="$(mktemp "$(dirname "$target")/.jdownloader-config.XXXXXX")"
  mode="$(stat -f '%Lp' "$target")"
  if ! jq "$filter" "$target" > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  chmod "$mode" "$temporary"
  mv "$temporary" "$target"
}

jd_was_running=0
if pgrep -f '/Applications/JDownloader 2/JDownloader2.app' >/dev/null 2>&1; then
  jd_was_running=1
fi
settings_changed=0
if [[ "$AUTO_START" == "TRUE" ]]; then
  settings="$JD_HOME/cfg/org.jdownloader.gui.views.linkgrabber.addlinksdialog.LinkgrabberSettings.json"
  if [[ -f "$settings" ]]; then
    if [[ "$(jq -r '[.linkgrabberautoconfirmenabled,.linkgrabberautostartenabled] == [true,true]' "$settings")" != "true" ]]; then
      atomic_jq_update "$settings" '.linkgrabberautoconfirmenabled = true | .linkgrabberautostartenabled = true'
      settings_changed=1
    fi
  else
    echo "WARNING: JDownloader autostart was requested, but its LinkGrabber settings file is missing: $settings" >&2
    echo "Open JDownloader once to initialize its profile, then rerun this command." >&2
  fi
fi

auth_settings="$JD_HOME/cfg/org.jdownloader.api.RemoteAPIConfig.externinterfaceauth.json"
if [[ -f "$auth_settings" ]]; then
  if [[ "$(jq -r 'index("watch-later-to-jdownloader") != null' "$auth_settings")" != "true" ]]; then
    atomic_jq_update "$auth_settings" '(. + ["watch-later-to-jdownloader"]) | unique'
    settings_changed=1
  fi
else
  echo "WARNING: JDownloader's trusted-source configuration is missing: $auth_settings" >&2
  echo "JDownloader may ask for Click'n'Load approval until its profile is initialized." >&2
fi
if [[ "$settings_changed" -eq 1 && "$jd_was_running" -eq 1 ]]; then
  echo "WARNING: JDownloader settings were updated on disk while the app was already running; a restart may be required before autostart/trusted-source changes take effect." >&2
fi

cnl_available=0
if [[ "$METHOD" == "auto" || "$METHOD" == "cnl" ]]; then
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 http://127.0.0.1:9666/flash/ >/dev/null 2>&1; then
    cnl_available=1
  elif [[ "$METHOD" == "auto" ]]; then
    open -gj -a "JDownloader2" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 http://127.0.0.1:9666/flash/ >/dev/null 2>&1; then
        cnl_available=1
        break
      fi
      sleep 1
    done
  fi
fi

run_marker="$(mktemp "$STATE_DIR/run-marker.XXXXXX")"
chmod 600 "$run_marker"

if [[ "$METHOD" == "cnl" || ("$METHOD" == "auto" && "$cnl_available" -eq 1) ]]; then
  if [[ "$cnl_available" -ne 1 ]]; then
    echo "JDownloader Click'n'Load is not reachable at http://127.0.0.1:9666/flash/" >&2
    echo "Start JDownloader or use: --method folderwatch" >&2
    exit 1
  fi

  response="$(
    curl -fsS --max-time 15 -X POST \
      --data-urlencode "source=watch-later-to-jdownloader" \
      --data-urlencode "urls@$new_urls" \
      http://127.0.0.1:9666/flash/add
  )"

  if [[ "$response" != *success* ]]; then
    echo "Click'n'Load did not return success. Response: $response" >&2
    exit 1
  fi

  cat "$new_urls" >> "$STATE_FILE"
  sort -u "$STATE_FILE" -o "$STATE_FILE"

  cat >&2 <<EOF
Found $total_count Watch Later URLs.
Sent $new_count new URLs to JDownloader via Click'n'Load.

If JDownloader asks for permission, allow the request.
EOF
  if start_quit_watcher "$run_marker"; then
    exit 0
  fi
  exit 3
fi

jq_args=(
  -Rn
  --arg packageName "$package_name"
  --arg autoStart "$AUTO_START"
  --arg downloadFolder "$DOWNLOAD_DIR"
)

jq_filter='
  [inputs | select(length > 0) | {
    text: .,
    packageName: $packageName,
    enabled: "TRUE",
    autoConfirm: "TRUE",
    autoStart: $autoStart,
    forcedStart: "FALSE",
    overwritePackagizerEnabled: false
  } + (if $downloadFolder == "" then {} else {downloadFolder: $downloadFolder} end)]
'

job_tmp="$(mktemp "$STATE_DIR/watchlater.crawljob.XXXXXX")"
chmod 600 "$job_tmp"
jq "${jq_args[@]}" "$jq_filter" < "$new_urls" > "$job_tmp"

mkdir -p "$WATCH_DIR"
job_file="$WATCH_DIR/watchlater-$(date '+%Y%m%d-%H%M%S').crawljob"
mv "$job_tmp" "$job_file"

cat "$new_urls" >> "$STATE_FILE"
sort -u "$STATE_FILE" -o "$STATE_FILE"

cat >&2 <<EOF
Found $total_count Watch Later URLs.
Sent $new_count new URLs to JDownloader:
$job_file

If JDownloader does not pick this up, enable:
Settings -> Extensions -> Folder Watch
Folder:
$WATCH_DIR
EOF
if start_quit_watcher "$run_marker"; then
  exit 0
fi
exit 3
