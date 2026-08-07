#!/bin/bash
# Install the single Market refresh LaunchAgent. Run once, with Ivo's permission.
set -euo pipefail
SRC="/Users/YOUR_USERNAME/Projects/Market/launchd"
DEST="$HOME/Library/LaunchAgents"
mkdir -p "$DEST"

# Retire the superseded direct-Python jobs and the cron dispatcher entry. The
# signed Market app is now the sole scheduler identity.
for label in com.ivo.market.ingest com.ivo.market.debrief com.ivo.market.watchdog; do
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  rm -f "$DEST/$label.plist"
done

current=$(crontab -l 2>/dev/null || true)
filtered=$(printf '%s\n' "$current" | grep -v '/Users/YOUR_USERNAME/.local/bin/market-cron' || true)
if [[ "$filtered" != "$current" ]]; then
  printf '%s\n' "$filtered" | crontab -
fi

install -m 755 "/Users/YOUR_USERNAME/Projects/Market/scripts/market-refresh" \
  "/Users/YOUR_USERNAME/.local/bin/market-refresh"
install -m 644 "$SRC/com.ivo.market.refresh.plist" \
  "$DEST/com.ivo.market.refresh.plist"
launchctl bootout "gui/$(id -u)/com.ivo.market.refresh" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$DEST/com.ivo.market.refresh.plist"
echo "Installed com.ivo.market.refresh. Verify with launchctl print gui/$(id -u)/com.ivo.market.refresh"
