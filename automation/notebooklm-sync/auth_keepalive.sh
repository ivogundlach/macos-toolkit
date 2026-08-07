#!/bin/bash

# Keep the NotebookLM cookie warm so it never silently stales out (as it did
# 2026-06-09, killing the hourly sync for 9 days). Scheduled once daily by
# com.ivo.notebooklm-auth-refresh (the hourly sync gate also self-heals via
# auth refresh when it detects a stale session).
#
# Note: `auth refresh` in notebooklm-py 0.7.2 exits 0 even on failure, so we
# detect problems by output, not exit code. `--quiet` only prints on error,
# so any output means the refresh could not renew the session.
#
# 2026-07-24: refresh FAILING is not the same as auth being DEAD. The old version
# printed "re-authenticate with 'notebooklm login'" for every non-empty output, so
# a DNS blip (2026-07-22: "[Errno 8] nodename nor servname provided") was logged
# as an auth expiry — a false alarm costing a manual browser login for a problem
# that fixes itself. Now: classify network errors as transient, and for anything
# else ASK THE AUTHORITATIVE CHECK (`auth check --test` does a live token fetch)
# before telling anyone to re-authenticate.

BIN="/opt/homebrew/bin/notebooklm"
LOG="/Users/YOUR_USERNAME/.local/state/notebooklm-sync/auth_keepalive.log"

# Transient connectivity, not credentials. Errno 8 = DNS; 51/60/61/65 = network
# unreachable / timed out / connection refused / no route to host.
NET_RE='nodename nor servname|Name or service not known|Temporary failure in name resolution|Connection (refused|reset|aborted)|Network is unreachable|No route to host|timed out|TimeoutError|Max retries exceeded|\[Errno (8|51|60|61|65)\]'

classify() {
    if printf '%s' "$1" | grep -qiE "$NET_RE"; then
        printf 'network'
    else
        printf 'other'
    fi
}

if [ "${1:-}" = "--selftest" ]; then
    fails=0
    check() {
        got="$(classify "$2")"
        if [ "$got" = "$1" ]; then echo "  PASS [$1] ${2:0:58}"
        else echo "  FAIL want=$1 got=$got: ${2:0:58}"; fails=$((fails+1)); fi
    }
    echo "auth_keepalive classifier selftest:"
    check network "Unexpected error: [Errno 8] nodename nor servname provided, or not known"
    check network "requests.exceptions.ConnectionError: Max retries exceeded with url"
    check network "socket.timeout: The read operation timed out"
    check network "OSError: [Errno 51] Network is unreachable"
    check other   "Session expired. Please run 'notebooklm login'."
    check other   "401 Unauthorized"
    check other   "Unexpected error: "
    [ "$fails" -eq 0 ] && echo "  ALL PASS" || echo "  $fails FAILED"
    exit "$fails"
fi

OUT="$("$BIN" auth refresh --quiet 2>&1)"
[ -n "$OUT" ] || exit 0

if [ "$(classify "$OUT")" = "network" ]; then
    echo "$(date): refresh deferred — transient network problem: $OUT" >> "$LOG"
    echo "$(date): no action needed; the daily schedule retries" >> "$LOG"
    exit 0
fi

# Refresh complained for a non-network reason. Only a live token fetch can tell a
# genuinely dead session from a refresh-path hiccup, so ask it before raising.
if CHECK="$("$BIN" auth check --test 2>&1)" && printf '%s' "$CHECK" | grep -qE 'Token fetch.*(pass|✓)'; then
    echo "$(date): refresh reported '$OUT' but a live token fetch PASSED — session healthy, no action" >> "$LOG"
    exit 0
fi

echo "$(date): AUTH EXPIRED — refresh failed and live token fetch failed: $OUT" >> "$LOG"
echo "$(date): re-authenticate with 'notebooklm login'" >> "$LOG"
