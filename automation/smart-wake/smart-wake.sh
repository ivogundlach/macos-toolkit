#!/bin/bash

SMART_WAKE_HOME="${SMART_WAKE_HOME:-${HOME}/.config/smart-wake}"
# shellcheck disable=SC1091
source "${SMART_WAKE_HOME}/lib.sh"

write_status() {
    local now="$1"
    local keep_awake="$2"
    local reason="$3"
    local mode="$4"
    local ssid="$5"
    local trusted="$6"
    local ac="$7"
    local battery="$8"
    local override_until="$9"
    local cooldown_until="${10}"

    {
        printf 'UPDATED_AT=%q\n' "$(date)"
        printf 'NOW=%q\n' "$now"
        printf 'KEEP_AWAKE=%q\n' "$keep_awake"
        printf 'REASON=%q\n' "$reason"
        printf 'MODE=%q\n' "$mode"
        printf 'SSID=%q\n' "$ssid"
        printf 'TRUSTED_WIFI=%q\n' "$trusted"
        printf 'AC_POWER=%q\n' "$ac"
        printf 'BATTERY_PERCENT=%q\n' "$battery"
        printf 'OVERRIDE_UNTIL=%q\n' "$override_until"
        printf 'COOLDOWN_UNTIL=%q\n' "$cooldown_until"
    } > "$STATUS_FILE"
}

start_cooldown() {
    local now="$1"
    local until=$((now + COOLDOWN_SECONDS))
    echo "$until" > "$COOLDOWN_UNTIL_FILE"
    : > "$COOLDOWN_NOTIFIED_FILE"
    log_msg "Cooldown started until $(format_epoch "$until")"
    maybe_notify_cooldown "$now" "$until"
}

record_cooldown_notification() {
    local until="$1"
    local label="$2"

    case "$label" in
        warn)
            cooldown_mark_notified "$until" "start"
            cooldown_mark_notified "$until" "warn"
            ;;
        start)
            cooldown_mark_notified "$until" "start"
            ;;
    esac
}

send_cooldown_notification() {
    local until="$1"
    local label="$2"
    local body="$3"
    local now="$4"
    local result attempts

    cooldown_mark_attempt "$until" "$label" "$now"
    send_notification "$body"
    result=$?
    if [ "$result" -eq 0 ]; then
        record_cooldown_notification "$until" "$label"
    elif [ "$result" -ne 75 ]; then
        cooldown_mark_notified "$until" "${label}-failed"
    else
        attempts=$(cooldown_attempt_count "$until" "$label")
        if [ "$attempts" -ge "$COOLDOWN_NOTIFY_MAX_ATTEMPTS" ]; then
            cooldown_mark_notified "$until" "${label}-failed"
            log_msg "Gave up on the ${label} cooldown notification after ${attempts} attempts"
        fi
    fi
    return "$result"
}

cooldown_notification_attempted() {
    local until="$1"
    local label="$2"
    cooldown_was_notified "$until" "$label" || cooldown_was_notified "$until" "${label}-failed"
}

reply_guide() {
    cat <<'EOF'

Reply guide:
2h / 50min / 90min = keep awake
status = current state
sleep = clear override
12h = keep awake for 12 hours
EOF
}

cooldown_start_body() {
    printf 'Smart Wake cooldown started. Sleep in %s unless AC/trusted Wi-Fi returns.\n%s' \
        "$(format_remaining "$COOLDOWN_SECONDS")" "$(reply_guide)"
}

cooldown_warn_body() {
    printf 'Smart Wake: sleep in about %s.\n%s' \
        "$(format_remaining "$COOLDOWN_WARN_SECONDS")" "$(reply_guide)"
}

# Two messages per cooldown: one when the countdown starts, one final warning
# COOLDOWN_WARN_SECONDS before sleep.
maybe_notify_cooldown() {
    local now="$1"
    local until="$2"
    local remaining=$((until - now))

    if [ "$remaining" -le "$COOLDOWN_WARN_SECONDS" ] && [ "$remaining" -gt 0 ] &&
        ! cooldown_notification_attempted "$until" "warn"; then
        cooldown_retry_ready "$until" "warn" "$now" || return 0
        send_cooldown_notification "$until" "warn" "$(cooldown_warn_body)" "$now"
    elif [ "$remaining" -gt "$COOLDOWN_WARN_SECONDS" ] &&
        ! cooldown_notification_attempted "$until" "start"; then
        cooldown_retry_ready "$until" "start" "$now" || return 0
        send_cooldown_notification "$until" "start" "$(cooldown_start_body)" "$now"
    fi
}

maybe_notify_override() {
    local now="$1"
    local until="$2"
    local remaining=$((until - now))
    local result

    if [ "$remaining" -le 600 ] && [ "$remaining" -gt 0 ] &&
        ! override_was_notified "$until" "10min" &&
        ! override_was_notified "$until" "10min-failed"; then
        send_notification "Smart Wake: manual override ends in about 10 min.

Reply guide:
2h / 50min / 90min = keep awake
status = current state
sleep = clear override
12h = keep awake for 12 hours"
        result=$?
        if [ "$result" -eq 0 ]; then
            override_mark_notified "$until" "10min"
        elif [ "$result" -ne 75 ]; then
            override_mark_notified "$until" "10min-failed"
        fi
    fi
}

smart_wake_cycle() {
    load_config

    if background_wake_with_closed_lid; then
        log_msg "Skipped Smart Wake evaluation during a closed-lid background wake"
        return 0
    fi

    ssid=$(current_ssid)
    battery=$(battery_percent)
    now=$(now_epoch)
    ac=false
    ac_loss_grace=false
    disabled=false
    trusted=false
    keep_awake=false
    reason="not allowed"
    mode="battery"

    if background_wake_with_closed_lid; then
        log_msg "Skipped Smart Wake evaluation because the lid closed during state probing"
        return 0
    fi

    if on_ac_power; then
        ac=true
        echo "$now" > "$LAST_AC_SEEN_FILE"
    else
        last_ac_seen=$(read_epoch_file "$LAST_AC_SEEN_FILE")
        if [ -n "$last_ac_seen" ] &&
            [ "$((now - last_ac_seen))" -ge 0 ] &&
            [ "$((now - last_ac_seen))" -lt "$AC_POWER_LOSS_GRACE_SECONDS" ]; then
            ac_loss_grace=true
        fi
    fi

    if smart_wake_disabled_now; then
        disabled=true
    fi

    if [ "$disabled" = true ] && [ "$ac" = false ] && [ "$ac_loss_grace" = false ]; then
        reason="disabled until ${SMART_WAKE_DISABLED_END}"
    elif [ "$ac" = true ]; then
        keep_awake=true
        reason="AC power"
        mode="ac"
    elif [ "$ac_loss_grace" = true ]; then
        keep_awake=true
        reason="brief AC power interruption"
        mode="battery"
    elif is_trusted_wifi "$ssid"; then
        trusted=true
        keep_awake=true
        reason="trusted Wi-Fi: ${ssid}"
        mode="battery"
    fi

    if [ "$trusted" = false ] && is_trusted_wifi "$ssid"; then
        trusted=true
    fi

    override_until=$(read_epoch_file "$OVERRIDE_UNTIL_FILE")
    if [ "$disabled" = true ] && [ "$ac" = false ] && [ "$ac_loss_grace" = false ]; then
        if [ -n "$override_until" ]; then
            rm -f "$OVERRIDE_UNTIL_FILE" "$OVERRIDE_NOTIFIED_FILE"
            override_until=""
            log_msg "Manual override cleared because Smart Wake is disabled until ${SMART_WAKE_DISABLED_END}"
        fi
    elif [ -n "$override_until" ] && [ "$override_until" -gt "$now" ] 2>/dev/null; then
        if [ "$ac" = true ] || [ "$trusted" = true ]; then
            rm -f "$OVERRIDE_UNTIL_FILE" "$OVERRIDE_NOTIFIED_FILE"
            override_until=""
            log_msg "Manual override cleared because an always-on condition is active: ${reason}"
        else
            keep_awake=true
            reason="manual override until $(format_epoch "$override_until")"
            mode="battery"
            maybe_notify_override "$now" "$override_until"
        fi
    elif [ -n "$override_until" ]; then
        rm -f "$OVERRIDE_UNTIL_FILE" "$OVERRIDE_NOTIFIED_FILE"
        override_until=""
        log_msg "Manual override expired"
    fi

    cooldown_until=$(read_epoch_file "$COOLDOWN_UNTIL_FILE")

    if [ "$disabled" = true ] && [ "$ac" = false ] && [ "$ac_loss_grace" = false ]; then
        stop_caffeinate
        rm -f "$LAST_ALLOWED_FILE" "$ALLOWED_LOSS_SINCE_FILE" "$COOLDOWN_UNTIL_FILE" "$COOLDOWN_NOTIFIED_FILE"
    elif [ "$keep_awake" = true ]; then
        echo "$now" > "$LAST_ALLOWED_FILE"
        rm -f "$ALLOWED_LOSS_SINCE_FILE" "$COOLDOWN_UNTIL_FILE" "$COOLDOWN_NOTIFIED_FILE"
        ensure_caffeinate "$mode"
    else
        if ! clamshell_closed; then
            # Lid open: the user is present and macOS governs sleep directly.
            # Never start a cooldown countdown or send sleep warnings while the
            # lid is open, and cancel any cooldown already in progress.
            if [ -n "$cooldown_until" ] || [ -f "$LAST_ALLOWED_FILE" ] ||
                [ -f "$ALLOWED_LOSS_SINCE_FILE" ] || caffeinate_running; then
                log_msg "Lid open without an allowed condition; cancelling cooldown and allowing normal sleep"
            fi
            stop_caffeinate
            rm -f "$LAST_ALLOWED_FILE" "$ALLOWED_LOSS_SINCE_FILE" "$COOLDOWN_UNTIL_FILE" "$COOLDOWN_NOTIFIED_FILE"
            cooldown_until=""
        elif [ -n "$cooldown_until" ]; then
            if [ "$cooldown_until" -gt "$now" ] 2>/dev/null; then
                keep_awake=true
                reason="cooldown until $(format_epoch "$cooldown_until")"
                mode="battery"
                ensure_caffeinate "$mode"
                maybe_notify_cooldown "$now" "$cooldown_until"
            else
                log_msg "Cooldown expired"
                stop_caffeinate
                rm -f "$LAST_ALLOWED_FILE" "$ALLOWED_LOSS_SINCE_FILE" "$COOLDOWN_UNTIL_FILE" "$COOLDOWN_NOTIFIED_FILE"
                cooldown_until=""
            fi
        elif [ -f "$LAST_ALLOWED_FILE" ] || caffeinate_running; then
            loss_since=$(read_epoch_file "$ALLOWED_LOSS_SINCE_FILE")
            if [ -z "$loss_since" ]; then
                loss_since="$now"
                echo "$loss_since" > "$ALLOWED_LOSS_SINCE_FILE"
                log_msg "Allowed state disappeared; waiting ${TRUSTED_WIFI_LOSS_GRACE_SECONDS}s before cooldown"
            fi

            keep_awake=true
            reason="waiting for trusted Wi-Fi to settle"
            mode="battery"
            ensure_caffeinate "$mode"
            if [ "$((now - loss_since))" -ge "$TRUSTED_WIFI_LOSS_GRACE_SECONDS" ]; then
                rm -f "$ALLOWED_LOSS_SINCE_FILE"
                start_cooldown "$now"
                cooldown_until=$(read_epoch_file "$COOLDOWN_UNTIL_FILE")
                reason="cooldown until $(format_epoch "$cooldown_until")"
            fi
        else
            stop_caffeinate
            rm -f "$ALLOWED_LOSS_SINCE_FILE" "$COOLDOWN_UNTIL_FILE" "$COOLDOWN_NOTIFIED_FILE"
        fi
    fi

    if [ "$keep_awake" = false ]; then
        rm -f "$LAST_ALLOWED_FILE"
        clear_sleep_guard_lease
    else
        refresh_sleep_guard_lease "$now"
    fi

    handle_lid_lock "$keep_awake"

    write_status "$now" "$keep_awake" "$reason" "$mode" "$ssid" "$trusted" "$ac" "$battery" "${override_until:-}" "${cooldown_until:-}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    log_msg "smart-wake daemon started"
    while true; do
        smart_wake_cycle
        sleep "$SMART_WAKE_POLL_SECONDS"
    done
fi
