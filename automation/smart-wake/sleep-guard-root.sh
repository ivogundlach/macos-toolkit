#!/bin/bash
set -u

LEASE_FILE="/Users/YOUR_USERNAME/.config/smart-wake/state/sleep-guard-lease"
POLL_SECONDS=5
sleep_disabled=false

log_guard() {
    /usr/bin/logger -t smart-wake-sleep-guard "$*"
}

set_sleep_disabled() {
    local desired="$1"

    if [ "$desired" = true ] && [ "$sleep_disabled" = false ]; then
        /usr/bin/pmset -a disablesleep 1
        sleep_disabled=true
        log_guard "Enabled closed-lid sleep protection"
    elif [ "$desired" = false ] && [ "$sleep_disabled" = true ]; then
        /usr/bin/pmset -a disablesleep 0
        sleep_disabled=false
        log_guard "Disabled closed-lid sleep protection"
    fi
}

restore_sleep() {
    /usr/bin/pmset -a disablesleep 0
    log_guard "Restored normal sleep behavior"
}

trap 'restore_sleep; exit 0' HUP INT TERM

# Never inherit a stale setting from an interrupted previous run.
/usr/bin/pmset -a disablesleep 0

while true; do
    now=$(/bin/date +%s)
    lease_until=""
    if [ -f "$LEASE_FILE" ]; then
        lease_until=$(/usr/bin/tr -dc '0-9' < "$LEASE_FILE")
    fi

    if [ -n "$lease_until" ] && [ "$lease_until" -gt "$now" ] 2>/dev/null; then
        set_sleep_disabled true
    else
        set_sleep_disabled false
    fi

    /bin/sleep "$POLL_SECONDS"
done
