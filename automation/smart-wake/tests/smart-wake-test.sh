#!/bin/bash
set -u

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export SMART_WAKE_HOME="$PROJECT_DIR"
export SMART_WAKE_STATE_DIR="$TEST_ROOT/state"
mkdir -p "$SMART_WAKE_STATE_DIR"

# shellcheck disable=SC1090
source "$PROJECT_DIR/smart-wake.sh"

failures=0

assert_file_missing() {
    if [ -e "$1" ]; then
        printf 'FAIL: expected missing file %s\n' "$1"
        failures=$((failures + 1))
    fi
}

assert_file_value() {
    local expected="$1"
    local file="$2"
    local actual=""
    [ -f "$file" ] && actual=$(cat "$file")
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: expected %s in %s, got %s\n' "$expected" "$file" "$actual"
        failures=$((failures + 1))
    fi
}

reset_state() {
    rm -rf "$SMART_WAKE_STATE_DIR"
    mkdir -p "$SMART_WAKE_STATE_DIR"
}

load_config() {
    COOLDOWN_SECONDS=1800
    COOLDOWN_WARN_SECONDS=300
    COOLDOWN_NOTIFY_MAX_ATTEMPTS=3
    COOLDOWN_NOTIFY_RETRY_SECONDS=60
    TRUSTED_WIFI_LOSS_GRACE_SECONDS=90
    AC_POWER_LOSS_GRACE_SECONDS=90
    SLEEP_GUARD_LEASE_SECONDS=90
    SMART_WAKE_DISABLED_END=08:00
}
battery_percent() { printf '80\n'; }
on_ac_power() { return 1; }
smart_wake_disabled_now() { return 1; }
is_trusted_wifi() { [ "${1:-}" = "trusted" ]; }
caffeinate_running() { return 1; }
ensure_caffeinate() { :; }
stop_caffeinate() { :; }
send_notification() { return 75; }
write_status() { :; }
log_msg() { :; }

# Closing the lid while Smart Wake remains active locks once per lid closure.
reset_state
lock_marker="$TEST_ROOT/lock-called"
clamshell_closed() { return 0; }
lock_current_session() { echo called >> "$lock_marker"; return 0; }
handle_lid_lock true
handle_lid_lock true
assert_file_value called "$lock_marker"
[ -f "$LID_LOCKED_FILE" ] || { printf 'FAIL: lid lock state was not recorded\n'; failures=$((failures + 1)); }
clamshell_closed() { return 1; }
handle_lid_lock true
assert_file_missing "$LID_LOCKED_FILE"

# Closed-lid background wakes must not probe Wi-Fi or mutate cooldown state.
reset_state
echo 100 > "$LAST_ALLOWED_FILE"
ssid_probe_marker="$TEST_ROOT/ssid-probed"
background_wake_with_closed_lid() { return 0; }
current_ssid() { touch "$ssid_probe_marker"; printf 'trusted\n'; }
now_epoch() { printf '200\n'; }
smart_wake_cycle
[ ! -e "$ssid_probe_marker" ] || { printf 'FAIL: probed SSID during background wake\n'; failures=$((failures + 1)); }
assert_file_missing "$COOLDOWN_UNTIL_FILE"
assert_file_missing "$SLEEP_GUARD_LEASE_FILE"

# A momentary AC interruption remains protected even during the disabled window.
reset_state
echo 1000 > "$LAST_AC_SEEN_FILE"
background_wake_with_closed_lid() { return 1; }
current_ssid() { printf '\n'; }
now_epoch() { printf '1040\n'; }
smart_wake_disabled_now() { return 0; }
smart_wake_cycle
assert_file_value 1130 "$SLEEP_GUARD_LEASE_FILE"

# Once the AC grace expires, the disabled window restores normal sleep.
now_epoch() { printf '1100\n'; }
smart_wake_cycle
assert_file_missing "$SLEEP_GUARD_LEASE_FILE"
smart_wake_disabled_now() { return 1; }

# The cooldown countdown only applies with the lid closed; the rest of the
# cooldown tests below run in that state.
clamshell_closed() { return 0; }

# A transient SSID miss starts only the grace timer.
reset_state
echo 100 > "$LAST_ALLOWED_FILE"
background_wake_with_closed_lid() { return 1; }
current_ssid() { printf '\n'; }
now_epoch() { printf '1000\n'; }
smart_wake_cycle
assert_file_value 1000 "$ALLOWED_LOSS_SINCE_FILE"
assert_file_missing "$COOLDOWN_UNTIL_FILE"

# A trusted SSID return clears the grace state without starting a cooldown.
current_ssid() { printf 'trusted\n'; }
now_epoch() { printf '1040\n'; }
smart_wake_cycle
assert_file_missing "$ALLOWED_LOSS_SINCE_FILE"
assert_file_missing "$COOLDOWN_UNTIL_FILE"
assert_file_value 1130 "$SLEEP_GUARD_LEASE_FILE"

# After the grace period, cooldown time is based on the fresh post-probe clock.
reset_state
echo 1900 > "$LAST_ALLOWED_FILE"
echo 1900 > "$ALLOWED_LOSS_SINCE_FILE"
probe_finished="$TEST_ROOT/probe-finished"
current_ssid() { touch "$probe_finished"; printf '\n'; }
now_epoch() { [ -e "$probe_finished" ] && printf '2005\n' || printf '1900\n'; }
smart_wake_cycle
assert_file_value 3805 "$COOLDOWN_UNTIL_FILE"

# An expired cooldown stops once; it must not start another countdown.
reset_state
echo 2000 > "$LAST_ALLOWED_FILE"
echo 2500 > "$COOLDOWN_UNTIL_FILE"
current_ssid() { printf '\n'; }
now_epoch() { printf '2600\n'; }
smart_wake_cycle
assert_file_missing "$LAST_ALLOWED_FILE"
assert_file_missing "$COOLDOWN_UNTIL_FILE"
assert_file_missing "$SLEEP_GUARD_LEASE_FILE"

# Failed/deferred sends are not recorded as delivered; success is recorded once.
reset_state
load_config
send_notification() { return 75; }
maybe_notify_cooldown 1000 2800
cooldown_was_notified 2800 start && { printf 'FAIL: deferred start notification recorded as delivered\n'; failures=$((failures + 1)); }
send_notification() { return 0; }
maybe_notify_cooldown 1060 2800
grep -qx '2800:start' "$COOLDOWN_NOTIFIED_FILE" || { printf 'FAIL: successful start notification not recorded\n'; failures=$((failures + 1)); }

# A delivered notification is sent exactly once, however many cycles run.
reset_state
load_config
sends=0
send_notification() { sends=$((sends + 1)); return 0; }
for now in 1000 1010 1020 1200 1600; do
    maybe_notify_cooldown "$now" 2800
done
[ "$sends" -eq 1 ] || { printf 'FAIL: expected 1 start notification, sent %s\n' "$sends"; failures=$((failures + 1)); }

# Cooldown warns only at the start and COOLDOWN_WARN_SECONDS before sleep.
reset_state
load_config
sends=0
send_notification() { sends=$((sends + 1)); return 0; }
now=1000
while [ "$now" -le 2800 ]; do
    maybe_notify_cooldown "$now" 2800
    now=$((now + 10))
done
[ "$sends" -eq 2 ] || { printf 'FAIL: expected 2 cooldown notifications, sent %s\n' "$sends"; failures=$((failures + 1)); }
cooldown_was_notified 2800 warn || { printf 'FAIL: warn notification not recorded\n'; failures=$((failures + 1)); }

# An undeliverable send retries, but stops after COOLDOWN_NOTIFY_MAX_ATTEMPTS.
reset_state
load_config
sends=0
send_notification() { sends=$((sends + 1)); return 75; }
now=1000
while [ "$now" -le 2400 ]; do
    maybe_notify_cooldown "$now" 2800
    now=$((now + 10))
done
[ "$sends" -eq 3 ] || { printf 'FAIL: expected 3 bounded retries, sent %s\n' "$sends"; failures=$((failures + 1)); }

# Retries are spaced by COOLDOWN_NOTIFY_RETRY_SECONDS, not sent every cycle.
reset_state
load_config
sends=0
send_notification() { sends=$((sends + 1)); return 75; }
for now in 1000 1010 1020 1030; do
    maybe_notify_cooldown "$now" 2800
done
[ "$sends" -eq 1 ] || { printf 'FAIL: expected 1 send within the retry interval, sent %s\n' "$sends"; failures=$((failures + 1)); }

# Lid open: losing the allowed state must not start a cooldown or notify.
reset_state
clamshell_closed() { return 1; }
notify_marker="$TEST_ROOT/lid-open-notify"
send_notification() { touch "$notify_marker"; return 0; }
echo 100 > "$LAST_ALLOWED_FILE"
background_wake_with_closed_lid() { return 1; }
current_ssid() { printf '\n'; }
now_epoch() { printf '1000\n'; }
smart_wake_cycle
assert_file_missing "$ALLOWED_LOSS_SINCE_FILE"
assert_file_missing "$COOLDOWN_UNTIL_FILE"
assert_file_missing "$SLEEP_GUARD_LEASE_FILE"
assert_file_missing "$LAST_ALLOWED_FILE"
[ ! -e "$notify_marker" ] || { printf 'FAIL: sent a sleep notification while the lid was open\n'; failures=$((failures + 1)); }

# Opening the lid cancels a cooldown already in progress and stops notifying.
reset_state
clamshell_closed() { return 1; }
notify_marker="$TEST_ROOT/lid-open-cancel-notify"
send_notification() { touch "$notify_marker"; return 0; }
echo 100 > "$LAST_ALLOWED_FILE"
echo 2000 > "$COOLDOWN_UNTIL_FILE"
echo '2000:start' > "$COOLDOWN_NOTIFIED_FILE"
background_wake_with_closed_lid() { return 1; }
current_ssid() { printf '\n'; }
now_epoch() { printf '1500\n'; }
smart_wake_cycle
assert_file_missing "$COOLDOWN_UNTIL_FILE"
assert_file_missing "$COOLDOWN_NOTIFIED_FILE"
assert_file_missing "$SLEEP_GUARD_LEASE_FILE"
[ ! -e "$notify_marker" ] || { printf 'FAIL: notified during cooldown after the lid opened\n'; failures=$((failures + 1)); }

if [ "$failures" -ne 0 ]; then
    exit 1
fi
printf 'smart-wake tests passed\n'
