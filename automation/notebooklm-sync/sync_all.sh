#!/bin/bash

# Define paths
NOTES_DIR="/Users/YOUR_USERNAME/Files"
SYNC_DIR="/Users/YOUR_USERNAME/.local/state/notebooklm-sync"
LOG_FILE="$SYNC_DIR/sync_automation.log"
NOTEBOOKLM_BIN="/opt/homebrew/bin/notebooklm"

# Add a timestamp to the log
echo "=== Sync Started: $(date) ===" >> "$LOG_FILE"

# Network-validated auth gate. Two traps to avoid:
#   1. Bare `auth check` only proves the cookie file PARSES (it passed even
#      while auth was dead for 9 days in June 2026). `--test` does a real
#      token-fetch.
#   2. In notebooklm-py 0.7.2 `auth check --test` EXITS 0 even when auth is
#      broken — so we must parse the JSON "status" field, not the exit code.
auth_ok() {
    "$NOTEBOOKLM_BIN" auth check --test --json 2>/dev/null \
        | grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"'
}

# Is the Mac actually online and able to reach Google? A failed token-fetch
# says NOTHING about auth when the machine is simply offline: DNS/connection
# errors (e.g. "[Errno 8] nodename nor servname provided") surfaced as false
# "auth expired" alarms on 2026-06-21. We only notify "re-authenticate" when
# the network is UP but auth still fails — a genuine credential problem, not an
# outage. Any HTTP response (even 3xx/4xx) proves reachability, so no -f.
network_up() {
    /usr/bin/curl -sS -o /dev/null --max-time 8 https://notebooklm.google.com >/dev/null 2>&1
}

if ! auth_ok; then
    echo "Auth stale; attempting in-place refresh..." >> "$LOG_FILE"
    "$NOTEBOOKLM_BIN" auth refresh --quiet >> "$LOG_FILE" 2>&1
fi

if auth_ok; then
    echo "Running NotebookLM Sync..." >> "$LOG_FILE"
    NOTEBOOKLM_BIN="$NOTEBOOKLM_BIN" /usr/bin/python3 "$SYNC_DIR/notebooklm_sync.py" >> "$LOG_FILE" 2>&1
elif ! network_up; then
    # Machine is offline — NOT an auth problem. Skip quietly; the next hourly
    # run retries. Deliberately no notification.
    echo "--- Network unavailable; sync SKIPPED (will retry next run). No auth action needed." >> "$LOG_FILE"
else
    # Network is up but auth still fails => genuine credential expiry. Loud +
    # actionable instead of silently looping a doomed sync.
    echo "!!! AUTH EXPIRED — NotebookLM sync SKIPPED. Re-authenticate with: notebooklm login" >> "$LOG_FILE"
    /usr/bin/osascript -e 'display notification "Run: notebooklm login" with title "NotebookLM sync: auth expired"' >/dev/null 2>&1 || true
fi

echo "=== Sync Completed: $(date) ===" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
