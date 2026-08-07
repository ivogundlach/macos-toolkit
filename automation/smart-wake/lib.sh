#!/bin/bash

SMART_WAKE_HOME="${SMART_WAKE_HOME:-${HOME}/.config/smart-wake}"
CONFIG_FILE="${SMART_WAKE_HOME}/config.env"
STATE_DIR="${SMART_WAKE_STATE_DIR:-${SMART_WAKE_HOME}/state}"
PID_FILE="/tmp/smart-wake-caffeinate.pid"
MODE_FILE="${STATE_DIR}/caffeinate-mode"
LOG_FILE="/tmp/smartwake.log"
ERR_FILE="/tmp/smartwake.err"
OVERRIDE_UNTIL_FILE="${STATE_DIR}/override-until"
OVERRIDE_NOTIFIED_FILE="${STATE_DIR}/override-notified"
COOLDOWN_UNTIL_FILE="${STATE_DIR}/cooldown-until"
COOLDOWN_NOTIFIED_FILE="${STATE_DIR}/cooldown-notified"
LAST_ALLOWED_FILE="${STATE_DIR}/last-allowed"
ALLOWED_LOSS_SINCE_FILE="${STATE_DIR}/allowed-loss-since"
LAST_AC_SEEN_FILE="${STATE_DIR}/last-ac-seen"
LID_LOCKED_FILE="${STATE_DIR}/lid-locked"
STATUS_FILE="${STATE_DIR}/status.env"
SLEEP_GUARD_LEASE_FILE="${STATE_DIR}/sleep-guard-lease"
DISCORD_WEBHOOK_FILE="${SMART_WAKE_HOME}/discord-webhook-url"

mkdir -p "$STATE_DIR"

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
    : "${ALLOWED_WIFI_SSIDS:=}"
    : "${COOLDOWN_SECONDS:=1800}"
    : "${COOLDOWN_WARN_SECONDS:=300}"
    : "${COOLDOWN_NOTIFY_MAX_ATTEMPTS:=3}"
    : "${COOLDOWN_NOTIFY_RETRY_SECONDS:=60}"
    : "${SMART_WAKE_POLL_SECONDS:=10}"
    : "${TRUSTED_WIFI_LOSS_GRACE_SECONDS:=90}"
    : "${AC_POWER_LOSS_GRACE_SECONDS:=90}"
    : "${SLEEP_GUARD_LEASE_SECONDS:=90}"
    : "${DISCORD_MENTION:=@everyone}"
    : "${SMART_WAKE_DISABLED_START:=}"
    : "${SMART_WAKE_DISABLED_END:=}"
}

log_msg() {
    printf '%s: %s\n' "$(date)" "$*" >> "$LOG_FILE"
}

now_epoch() {
    date +%s
}

read_epoch_file() {
    local file="$1"
    if [ -f "$file" ]; then
        tr -dc '0-9' < "$file"
    fi
}

format_epoch() {
    local epoch="$1"
    if [ -n "$epoch" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
        date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z'
    else
        printf 'not set'
    fi
}

format_remaining() {
    local seconds="$1"
    if [ -z "$seconds" ] || [ "$seconds" -le 0 ] 2>/dev/null; then
        printf '0m'
        return
    fi
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    if [ "$hours" -gt 0 ]; then
        printf '%dh %dm' "$hours" "$minutes"
    else
        printf '%dm' "$minutes"
    fi
}

parse_duration_seconds() {
    local raw="$*"
    local compact
    compact=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    if [[ "$compact" =~ ^([0-9]+)(h|hr|hrs|hour|hours)$ ]]; then
        printf '%s\n' "$((${BASH_REMATCH[1]} * 3600))"
        return 0
    fi

    if [[ "$compact" =~ ^([0-9]+)(m|min|mins|minute|minutes)$ ]]; then
        printf '%s\n' "$((${BASH_REMATCH[1]} * 60))"
        return 0
    fi

    return 1
}

current_ssid() {
    local ssid
    ssid=$(networksetup -getairportnetwork en0 2>/dev/null | awk -F': ' '/Current Wi-Fi Network|Current AirPort Network/ {print $2}')
    if [ -n "$ssid" ]; then
        printf '%s\n' "$ssid"
        return 0
    fi

    "${SMART_WAKE_HOME}/wifi-ssid.py" 2>/dev/null
}

is_trusted_wifi() {
    local ssid="$1"
    local entry
    [ -n "$ssid" ] || return 1
    IFS=',' read -ra entries <<< "$ALLOWED_WIFI_SSIDS"
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        if [ "$entry" = "$ssid" ]; then
            return 0
        fi
    done
    return 1
}

on_ac_power() {
    pmset -g batt 2>/dev/null | grep -q "AC Power"
}

background_wake_with_closed_lid() {
    local power_state
    power_state=$(ioreg -r -n IOPMrootDomain -d 1 2>/dev/null) || return 1

    # When the sleep guard is active, the daemon must continue evaluating
    # power, Wi-Fi, and overrides even though the lid is closed.
    grep -q '"SleepDisabled" = Yes' <<< "$power_state" && return 1

    grep -q '"AppleClamshellState" = Yes' <<< "$power_state" &&
        grep -q '"IOPMUserIsActive" = No' <<< "$power_state"
}

clamshell_closed() {
    ioreg -r -n IOPMrootDomain -d 1 2>/dev/null |
        grep -q '"AppleClamshellState" = Yes'
}

lock_current_session() {
    local cg_session="/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    local screen_saver="/System/Library/CoreServices/ScreenSaverEngine.app"

    if [ -x "$cg_session" ]; then
        "$cg_session" -suspend >/dev/null 2>&1 &
        log_msg "Locked the session because the lid closed while Smart Wake remained active"
        return 0
    fi

    if [ -d "$screen_saver" ]; then
        /usr/bin/open -gja "$screen_saver" >/dev/null 2>&1 || return 1
        /bin/sleep 1
        /usr/bin/pmset displaysleepnow >/dev/null 2>&1 || return 1
        log_msg "Locked the session and powered off the display because the lid closed while Smart Wake remained active"
        return 0
    fi

    log_msg "Could not lock the session: no supported lock mechanism is available"
    return 1
}

handle_lid_lock() {
    local keep_awake="$1"

    if [ "$keep_awake" = true ] && clamshell_closed; then
        if [ ! -f "$LID_LOCKED_FILE" ]; then
            if lock_current_session; then
                : > "$LID_LOCKED_FILE"
            fi
        fi
    else
        rm -f "$LID_LOCKED_FILE"
    fi
}

refresh_sleep_guard_lease() {
    local now="$1"
    local lease_until=$((now + SLEEP_GUARD_LEASE_SECONDS))
    local temporary="${SLEEP_GUARD_LEASE_FILE}.tmp.$$"

    printf '%s\n' "$lease_until" > "$temporary"
    mv -f "$temporary" "$SLEEP_GUARD_LEASE_FILE"
}

clear_sleep_guard_lease() {
    rm -f "$SLEEP_GUARD_LEASE_FILE"
}

time_to_minutes() {
    local value="$1"
    local hour minute

    if [[ "$value" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        hour="${BASH_REMATCH[1]}"
        minute="${BASH_REMATCH[2]}"
        if [ "$hour" -ge 0 ] 2>/dev/null && [ "$hour" -le 23 ] && [ "$minute" -ge 0 ] && [ "$minute" -le 59 ]; then
            printf '%s\n' "$((10#$hour * 60 + 10#$minute))"
            return 0
        fi
    fi

    return 1
}

smart_wake_disabled_now() {
    local start end now_minutes

    [ -n "$SMART_WAKE_DISABLED_START" ] || return 1
    [ -n "$SMART_WAKE_DISABLED_END" ] || return 1

    start=$(time_to_minutes "$SMART_WAKE_DISABLED_START") || return 1
    end=$(time_to_minutes "$SMART_WAKE_DISABLED_END") || return 1
    now_minutes=$((10#$(date '+%H') * 60 + 10#$(date '+%M')))

    if [ "$start" -eq "$end" ]; then
        return 1
    fi

    if [ "$start" -lt "$end" ]; then
        [ "$now_minutes" -ge "$start" ] && [ "$now_minutes" -lt "$end" ]
    else
        [ "$now_minutes" -ge "$start" ] || [ "$now_minutes" -lt "$end" ]
    fi
}

battery_percent() {
    pmset -g batt 2>/dev/null | grep -Eo '[0-9]+%' | head -n 1 | tr -d '%'
}

caffeinate_running() {
    local pid
    [ -f "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

stop_caffeinate() {
    local pid
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$PID_FILE" "$MODE_FILE"
}

ensure_caffeinate() {
    local mode="$1"
    local current_mode=""

    if [ -f "$MODE_FILE" ]; then
        current_mode=$(cat "$MODE_FILE" 2>/dev/null)
    fi

    if caffeinate_running && [ "$current_mode" = "$mode" ]; then
        return 0
    fi

    stop_caffeinate

    if [ "$mode" = "ac" ]; then
        caffeinate -i -s &
    else
        caffeinate -i &
    fi

    echo $! > "$PID_FILE"
    echo "$mode" > "$MODE_FILE"
    log_msg "Started caffeinate mode=${mode} pid=$(cat "$PID_FILE")"
}

send_discord() {
    local body="$1"
    local webhook_url payload http_code

    [ -s "$DISCORD_WEBHOOK_FILE" ] || return 75
    webhook_url=$(cat "$DISCORD_WEBHOOK_FILE")
    payload=$(/usr/bin/python3 - "$body" "$DISCORD_MENTION" <<'PY'
import json
import sys

body, mention = sys.argv[1:3]
content = f"{mention}\n{body}" if mention else body
allowed_mentions = {"parse": ["everyone"]} if mention == "@everyone" else {"parse": []}
print(json.dumps({
    "content": content,
    "username": "Smart Wake",
    "allowed_mentions": allowed_mentions,
}))
PY
    ) || return 75

    http_code=$(printf '%s' "$payload" | curl -sS --max-time 10 \
        -o /dev/null -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        --data-binary @- "${webhook_url}?wait=true") || {
        log_msg "Discord notification request failed"
        return 75
    }

    if [ "$http_code" = "200" ]; then
        log_msg "Confirmed Discord notification creation"
        return 0
    fi

    log_msg "Discord notification failed with HTTP ${http_code}"
    return 75
}

send_notification() {
    local body="$1"
    send_discord "$body"
}

cooldown_mark_notified() {
    local cooldown_until="$1"
    local label="$2"
    printf '%s:%s\n' "$cooldown_until" "$label" >> "$COOLDOWN_NOTIFIED_FILE"
}

cooldown_was_notified() {
    local cooldown_until="$1"
    local label="$2"
    [ -f "$COOLDOWN_NOTIFIED_FILE" ] && grep -qx "${cooldown_until}:${label}" "$COOLDOWN_NOTIFIED_FILE"
}

# A send that never reaches Discord (result 75) stays unrecorded so it can be
# retried, but Discord may have created the message anyway when curl timed out
# waiting for the response. Attempt markers bound those retries so one flaky
# send cannot repost every poll cycle for the rest of the cooldown.
cooldown_mark_attempt() {
    local cooldown_until="$1"
    local label="$2"
    local now="$3"
    printf '%s:%s-attempt:%s\n' "$cooldown_until" "$label" "$now" >> "$COOLDOWN_NOTIFIED_FILE"
}

cooldown_attempts() {
    local cooldown_until="$1"
    local label="$2"
    [ -f "$COOLDOWN_NOTIFIED_FILE" ] || return 0
    grep "^${cooldown_until}:${label}-attempt:" "$COOLDOWN_NOTIFIED_FILE"
}

cooldown_attempt_count() {
    local count
    count=$(cooldown_attempts "$1" "$2" | grep -c '')
    printf '%s\n' "${count:-0}"
}

cooldown_retry_ready() {
    local cooldown_until="$1"
    local label="$2"
    local now="$3"
    local last

    last=$(cooldown_attempts "$cooldown_until" "$label" | tail -n 1 | cut -d: -f3)
    if [ -z "$last" ]; then
        return 0
    fi
    [ "$((now - last))" -ge "$COOLDOWN_NOTIFY_RETRY_SECONDS" ]
}

override_mark_notified() {
    local override_until="$1"
    local label="$2"
    printf '%s:%s\n' "$override_until" "$label" >> "$OVERRIDE_NOTIFIED_FILE"
}

override_was_notified() {
    local override_until="$1"
    local label="$2"
    [ -f "$OVERRIDE_NOTIFIED_FILE" ] && grep -qx "${override_until}:${label}" "$OVERRIDE_NOTIFIED_FILE"
}
