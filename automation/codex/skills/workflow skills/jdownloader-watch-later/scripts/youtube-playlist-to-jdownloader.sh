#!/usr/bin/env bash
set -euo pipefail

PLAYLIST=""
BROWSER=""
BROWSER_EXPLICIT=0
NO_BROWSER_COOKIES=0
METHOD="auto"
DRY_RUN=0
ADD_ALL=0
AUTO_START=1
QUIT_ON_COMPLETE=1
STATE_DIR="${JDOWNLOADER_STATE_DIR:-/Users/YOUR_USERNAME/.local/state/jdownloader-watch-later}"
PLAYLISTS_FILE="$STATE_DIR/playlists.json"
JD_HOME="/Applications/JDownloader 2"
WATCH_DIR=""
DOWNLOAD_DIR=""
DEFAULT_DOWNLOAD_ROOT="/Users/YOUR_USERNAME/Files/YouTube"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENUMERATOR="${JDOWNLOADER_PLAYLIST_ENUMERATOR:-$SCRIPT_DIR/enumerate-youtube-playlist.py}"
QUIT_WATCHER="${JDOWNLOADER_QUIT_WATCHER:-$SCRIPT_DIR/quit-jdownloader-on-complete.sh}"
WATCHER_LAUNCHER="${JDOWNLOADER_WATCHER_LAUNCHER:-$SCRIPT_DIR/launch-quit-watcher.sh}"

usage() {
  cat <<'USAGE'
Usage:
  youtube-playlist-to-jdownloader.sh --playlist ALIAS_OR_ID_OR_URL [options]

Primary path:
  Uses yt-dlp with authenticated browser cookies. No YouTube API key.

Options:
  --playlist VALUE      Playlist alias, playlist ID, or YouTube playlist URL.
  --browser VALUE       Strict cookie browser: safari or firefox.
                        Default: public first, then Safari, then Firefox.
  --no-browser-cookies  Disable automatic browser-cookie fallback.
  --method VALUE        auto, cnl, or folderwatch. Default: auto
  --download-dir PATH   Optional JDownloader download folder.
  --all                 Re-send all visible playlist links.
  --dry-run             Print links only. Do not send to JDownloader.
  --no-autostart        Do not set JDownloader autostart settings/crawljob flags.
  --keep-open           Do not quit JDownloader after downloads complete.
  --quit-on-complete    Quit JDownloader after downloads complete. Default.
  -h, --help            Show this help.

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
    --playlist)
      PLAYLIST="${2:?Missing value for --playlist}"
      shift 2
      ;;
    --browser)
      BROWSER="${2:?Missing value for --browser}"
      BROWSER_EXPLICIT=1
      shift 2
      ;;
    --no-browser-cookies)
      NO_BROWSER_COOKIES=1
      shift
      ;;
    --method)
      METHOD="${2:?Missing value for --method}"
      case "$METHOD" in
        auto|cnl|folderwatch) ;;
        *) echo "Invalid --method: $METHOD" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --download-dir)
      DOWNLOAD_DIR="${2:?Missing value for --download-dir}"
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
      AUTO_START=0
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

if [[ -z "$PLAYLIST" ]]; then
  usage >&2
  exit 2
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need curl
need jq
need sort
need comm
need python3

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
if [[ ! -x "$ENUMERATOR" ]]; then
  echo "Playlist enumerator missing or not executable: $ENUMERATOR" >&2
  exit 1
fi
JD_HOME="${JDOWNLOADER_HOME:-$JD_HOME}"
WATCH_DIR="${JDOWNLOADER_FOLDERWATCH_DIR:-${WATCH_DIR:-$JD_HOME/cfg/folderwatch}}"
download_root="${DOWNLOAD_DIR:-$DEFAULT_DOWNLOAD_ROOT}"

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

resolve_playlist_ref() {
  local value="$1"
  local mapped=""

  if [[ -f "$PLAYLISTS_FILE" ]]; then
    mapped="$(jq -r --arg key "$value" '.[$key] // empty' "$PLAYLISTS_FILE")"
  elif [[ "$value" == "ai" ]]; then
    mapped="PLEzb2QIVWIsT9YAOZm-dWAizqQEsQ68Tw"
  fi
  if [[ -n "$mapped" ]]; then
    printf '%s\n' "$mapped"
    return 0
  fi

  printf '%s\n' "$value"
}

playlist_ref="$(resolve_playlist_ref "$PLAYLIST")"
case "$playlist_ref" in
  http://*|https://*)
    playlist_url="$playlist_ref"
    ;;
  *'list='*)
    playlist_id="$(printf '%s\n' "$playlist_ref" | sed -E 's/.*[?&]list=([^&]+).*/\1/')"
    playlist_url="https://www.youtube.com/playlist?list=$playlist_id"
    ;;
  *)
    playlist_url="https://www.youtube.com/playlist?list=$playlist_ref"
    ;;
esac

safe_name="$(printf '%s' "$PLAYLIST" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//;s/-$//')"
state_file="$STATE_DIR/sent-${safe_name:-playlist}-playlist-urls.txt"

all_urls="$(mktemp)"
sorted_state="$(mktemp)"
new_urls="$(mktemp)"
enumeration_json="$(mktemp)"
job_tmp=""
run_marker=""
trap 'rm -f "$all_urls" "$sorted_state" "$new_urls" "$enumeration_json" ${job_tmp:+"$job_tmp"} ${run_marker:+"$run_marker"}' EXIT

enumerator_args=(--source "$playlist_url" --mode public)
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
  jq '.' "$enumeration_json" >&2 2>/dev/null || echo "Playlist enumeration failed without structured output." >&2
  exit 1
fi
jq -r '.result.urls[]?' "$enumeration_json" | sort -u > "$all_urls"
if [[ "$(jq -r '.status' "$enumeration_json")" == "partial" ]]; then
  echo "Playlist enumeration continued with degradations:" >&2
  jq -c '.degradation_reasons' "$enumeration_json" >&2
fi

if [[ ! -s "$all_urls" ]]; then
  if [[ "$(jq -r '.result.entry_count // -1' "$enumeration_json")" -eq 0 ]]; then
    echo "YouTube returned the playlist as empty. Nothing to send to JDownloader." >&2
    exit 0
  fi
  cat >&2 <<EOF
No playlist URLs were found using browser cookies.

Primary cookie path failed for:
$playlist_url

Try:
  $0 --playlist "$PLAYLIST" --browser safari
  $0 --playlist "$PLAYLIST" --browser firefox

If the playlist alias is unknown, use a targeted fallback lookup to find the playlist URL,
then save it in:
$PLAYLISTS_FILE
EOF
  exit 1
fi

if [[ "$ADD_ALL" -eq 1 ]]; then
  cp "$all_urls" "$new_urls"
else
  if [[ -f "$state_file" ]]; then
    sort -u "$state_file" > "$sorted_state"
  else
    : > "$sorted_state"
  fi
  comm -23 "$all_urls" "$sorted_state" > "$new_urls"
fi

total_count="$(wc -l < "$all_urls" | tr -d ' ')"
new_count="$(wc -l < "$new_urls" | tr -d ' ')"

if [[ "$new_count" -eq 0 ]]; then
  media_count=0
  if [[ -d "$download_root" ]]; then
    media_count="$(
      find "$download_root" \
        -path "$STATE_DIR" -prune -o \
        -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.m4a' -o -iname '*.mp3' \) \
        -print 2>/dev/null | wc -l | tr -d ' '
    )"
  fi

  if [[ "$media_count" -eq 0 ]]; then
    echo "Found $total_count playlist URLs already in sent-state, but no downloaded media files under $download_root. Resending all URLs." >&2
    cp "$all_urls" "$new_urls"
    new_count="$total_count"
  else
    echo "Found $total_count playlist URLs. No new URLs to send to JDownloader." >&2
    exit 0
  fi
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
  echo "Found $total_count playlist URLs. Would send $new_count URLs via $method_label." >&2
  jq -c '{network_performed,authenticated_read_performed,browser_path,attempts,degradation_reasons}' "$enumeration_json" >&2
  cat "$new_urls"
  exit 0
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
if [[ ! -f "$PLAYLISTS_FILE" ]]; then
  playlists_tmp="$(mktemp "$STATE_DIR/playlists.json.XXXXXX")"
  printf '{\n  "ai": "PLEzb2QIVWIsT9YAOZm-dWAizqQEsQ68Tw"\n}\n' > "$playlists_tmp"
  chmod 600 "$playlists_tmp"
  mv "$playlists_tmp" "$PLAYLISTS_FILE"
fi
touch "$state_file"
chmod 600 "$PLAYLISTS_FILE" "$state_file"

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
if [[ "$AUTO_START" -eq 1 ]]; then
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
  if [[ "$(jq -r 'index("youtube-playlist-to-jdownloader") != null' "$auth_settings")" != "true" ]]; then
    atomic_jq_update "$auth_settings" '(. + ["youtube-playlist-to-jdownloader"]) | unique'
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
  if curl -fsS --max-time 3 http://127.0.0.1:9666/flash/ >/dev/null 2>&1; then
    cnl_available=1
  elif [[ "$METHOD" == "auto" ]]; then
    open -gj -a "JDownloader2" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      if curl -fsS --max-time 2 http://127.0.0.1:9666/flash/ >/dev/null 2>&1; then
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
    echo "JDownloader Click'n'Load is not reachable. Start JDownloader or use --method folderwatch." >&2
    exit 1
  fi

  response="$(
    curl -fsS --max-time 15 -X POST \
      --data-urlencode "source=youtube-playlist-to-jdownloader" \
      --data-urlencode "urls@$new_urls" \
      http://127.0.0.1:9666/flash/add
  )"

  if [[ "$response" != *success* ]]; then
    echo "Click'n'Load did not return success. Response: $response" >&2
    exit 1
  fi

  cat "$new_urls" >> "$state_file"
  sort -u "$state_file" -o "$state_file"

  echo "Found $total_count playlist URLs. Sent $new_count new URLs to JDownloader via Click'n'Load." >&2
  if [[ "$AUTO_START" -eq 1 ]]; then
    echo "Auto-confirm and autostart settings were set to true." >&2
  fi
  if start_quit_watcher "$run_marker"; then
    exit 0
  fi
  exit 3
fi

auto_status="TRUE"
if [[ "$AUTO_START" -ne 1 ]]; then
  auto_status="FALSE"
fi

job_tmp="$(mktemp "$STATE_DIR/playlist.crawljob.XXXXXX")"
chmod 600 "$job_tmp"
jq -Rn \
  --arg packageName "YouTube Playlist $PLAYLIST $(date '+%Y-%m-%d %H:%M')" \
  --arg autoStart "$auto_status" \
  --arg downloadFolder "$DOWNLOAD_DIR" \
  '[inputs | select(length > 0) | {
    text: .,
    packageName: $packageName,
    enabled: "TRUE",
    autoConfirm: $autoStart,
    autoStart: $autoStart,
    forcedStart: $autoStart,
    overwritePackagizerEnabled: false
  } + (if $downloadFolder == "" then {} else {downloadFolder: $downloadFolder} end)]' \
  < "$new_urls" > "$job_tmp"

mkdir -p "$WATCH_DIR"
job_file="$WATCH_DIR/playlist-$(date '+%Y%m%d-%H%M%S').crawljob"
mv "$job_tmp" "$job_file"

cat "$new_urls" >> "$state_file"
sort -u "$state_file" -o "$state_file"

echo "Found $total_count playlist URLs. Wrote $new_count new URLs to Folder Watch: $job_file" >&2
if start_quit_watcher "$run_marker"; then
  exit 0
fi
exit 3
