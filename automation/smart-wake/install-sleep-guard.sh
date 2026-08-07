#!/bin/bash
set -euo pipefail

SOURCE_DIR="/Users/YOUR_USERNAME/.config/smart-wake"
HELPER="/Library/PrivilegedHelperTools/com.user.smartwake.sleep-guard"
PLIST="/Library/LaunchDaemons/com.user.smartwake.sleep-guard.plist"
LABEL="com.user.smartwake.sleep-guard"

/bin/mkdir -p /Library/PrivilegedHelperTools
/usr/bin/install -o root -g wheel -m 0755 "${SOURCE_DIR}/sleep-guard-root.sh" "$HELPER"
/usr/bin/install -o root -g wheel -m 0644 "${SOURCE_DIR}/com.user.smartwake.sleep-guard.plist" "$PLIST"

/bin/launchctl bootout system/$LABEL 2>/dev/null || true
/bin/launchctl bootstrap system "$PLIST"
/bin/launchctl kickstart -k system/$LABEL

printf 'Smart Wake closed-lid helper installed.\n'
