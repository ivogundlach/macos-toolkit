#!/bin/bash
# One-shot: remove low-value system-level updater launch items, then run a
# powermetrics energy sweep. Run with: sudo bash ~/.local/bin/process-cleanup-sudo-20260623.sh
# Every removed plist is backed up first. Idempotent (skips already-removed).
set -u

BK="/Users/YOUR_USERNAME/Library/.process-cleanup-backup-20260623"
mkdir -p "$BK/Library-LaunchAgents" "$BK/Library-LaunchDaemons"
CONSOLE_UID="$(stat -f%u /dev/console)"

# /Library/LaunchAgents (run in the console user's gui domain)
AGENTS=(
  com.google.keystone.agent           # Chrome auto-updater (Keystone)
  com.google.keystone.xpcservice      # Chrome auto-updater helper
  com.microsoft.OneDriveStandaloneUpdater
  com.microsoft.SyncReporter          # OneDrive telemetry reporter
  com.microsoft.update.agent          # Microsoft AutoUpdate agent
)
# /Library/LaunchDaemons (system domain)
DAEMONS=(
  com.microsoft.OneDriveStandaloneUpdaterDaemon
  com.microsoft.OneDriveUpdaterDaemon
  com.microsoft.autoupdate.helper     # Microsoft AutoUpdate privileged helper
)

echo "== Removing /Library/LaunchAgents =="
for l in "${AGENTS[@]}"; do
  f="/Library/LaunchAgents/$l.plist"
  if [ -f "$f" ]; then
    cp "$f" "$BK/Library-LaunchAgents/"
    launchctl bootout "gui/$CONSOLE_UID/$l" 2>/dev/null
    rm -f "$f"; echo "  removed: $l"
  else echo "  skip (absent): $l"; fi
done

echo "== Removing /Library/LaunchDaemons =="
for l in "${DAEMONS[@]}"; do
  f="/Library/LaunchDaemons/$l.plist"
  if [ -f "$f" ]; then
    cp "$f" "$BK/Library-LaunchDaemons/"
    launchctl bootout "system/$l" 2>/dev/null
    rm -f "$f"; echo "  removed: $l"
  else echo "  skip (absent): $l"; fi
done

echo "== powermetrics energy sweep (30s, ranked by energy impact) =="
REPORT="$BK/powermetrics-after.txt"
powermetrics --samplers tasks --show-process-energy -n 1 -i 30000 > "$REPORT" 2>/dev/null
chown "$CONSOLE_UID" "$REPORT"
echo "Report written: $REPORT"
echo "DONE."
