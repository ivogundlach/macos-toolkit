#!/bin/bash
set -euo pipefail

SMART_WAKE_HOME="${SMART_WAKE_HOME:-${HOME}/.config/smart-wake}"
# shellcheck disable=SC1090
source "${SMART_WAKE_HOME}/config.env"
: "${BATTERY_DISPLAY_SLEEP_MINUTES:=60}"
: "${AC_DISPLAY_SLEEP_MINUTES:=180}"

# Require authentication immediately after either the screen saver starts or
# the display powers off. Write both domains for compatibility across macOS versions.
/usr/bin/defaults write com.apple.screensaver askForPassword -int 1
/usr/bin/defaults write com.apple.screensaver askForPasswordDelay -int 0
/usr/bin/defaults -currentHost write com.apple.screensaver askForPassword -int 1
/usr/bin/defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0

# Do not introduce a separate screen-saver timeout. The display timers remain
# controlled by the battery and power-adapter values shown in System Settings.
/usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 0

/usr/bin/killall cfprefsd 2>/dev/null || true

printf 'Lock policy configured; display timing remains %sm on battery and %sm on AC.\n' \
    "$BATTERY_DISPLAY_SLEEP_MINUTES" "$AC_DISPLAY_SLEEP_MINUTES"
