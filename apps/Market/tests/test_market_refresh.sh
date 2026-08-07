#!/bin/bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/market-refresh-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/out/background_stamps" "$ROOT/state/background"
today=2026-08-04
touch "$ROOT/out/background_stamps/debrief.$today" "$ROOT/out/background_stamps/watchdog.$today"

# A missing/temp Market DB must make the isolated quote probe harmless when all regular
# stages are already stamped; the dispatcher still exits successfully and leaves a quote log.
MARKET_ROOT="$ROOT" \
MARKET_PYTHON=/Users/YOUR_USERNAME/Projects/Market/venv/bin/python \
MARKET_REFRESH_TODAY="$today" MARKET_REFRESH_NOW=0000 \
    /bin/bash /Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh
test -e "$ROOT/out/launchd_logs/position_quotes.out"

set +e
MARKET_ROOT="$ROOT" \
MARKET_PYTHON=/usr/bin/false \
MARKET_REFRESH_TODAY="$today" MARKET_REFRESH_NOW=1800 \
MARKET_REFRESH_FORCE_STAGE=ingest \
    /bin/bash /Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh
rc=$?
set -e

if [ "$rc" -ne 1 ]; then
    echo "expected failed adapter rc=1, got rc=$rc" >&2
    exit 1
fi
grep -q ' rc=1$' "$ROOT/state/background/ingest.last_failure"
test ! -e "$ROOT/out/background_stamps/ingest.$today"

MARKET_ROOT="$ROOT" \
MARKET_LAUNCHCTL=/usr/bin/true \
    /bin/bash /Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh --request-ingest
test -e "$ROOT/state/background/force_ingest.request"

set +e
MARKET_ROOT="$ROOT" \
MARKET_PYTHON=/usr/bin/false \
MARKET_REFRESH_TODAY="$today" MARKET_REFRESH_NOW=1800 \
    /bin/bash /Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh
marker_rc=$?
set -e
test "$marker_rc" -eq 1
test ! -e "$ROOT/state/background/force_ingest.request"

# A failed regular run is backed off, while explicit force requests remain durable.
MARKET_ROOT="$ROOT" MARKET_PYTHON=/usr/bin/false \
MARKET_REFRESH_TODAY="$today" MARKET_REFRESH_NOW=1800 \
    /bin/bash /Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh
test -e "$ROOT/state/background/ingest.next_retry_epoch"

mkdir -p "$ROOT/state/background/dispatcher.lock"
printf '%s\n' "$$" > "$ROOT/state/background/dispatcher.lock/pid"
MARKET_ROOT="$ROOT" MARKET_LAUNCHCTL=/usr/bin/true \
    /bin/bash /Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh --request-ingest
test -e "$ROOT/state/background/force_ingest.request"
rm -f "$ROOT/state/background/dispatcher.lock/pid"
rmdir "$ROOT/state/background/dispatcher.lock"

# A just-created lock without a pid is not stolen during the mkdir/pid race.
mkdir "$ROOT/state/background/dispatcher.lock"
MARKET_ROOT="$ROOT" MARKET_PYTHON=/usr/bin/false \
MARKET_REFRESH_TODAY="$today" MARKET_REFRESH_NOW=1800 \
    /bin/bash /Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh
test -d "$ROOT/state/background/dispatcher.lock"
echo "market refresh failure propagation passed"
