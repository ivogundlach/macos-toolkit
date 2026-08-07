#!/bin/zsh
# install.sh — staged install of app/dist/Market.app into /Applications.
#
# Staged upgrade (CONTRACTS.md §6: admin-writable /Applications, no auth):
#   1. require a built bundle (run build-app.sh first).
#   2. if the installed app is RUNNING, detect via pgrep and either quit it
#      (when run with --quit) or skip the install (default: ask, abort safely).
#   3. back up any prior /Applications/Market.app to a timestamped copy.
#   4. copy the new bundle into place.
#   5. verify the installed bundle's signature.
#   6. print the final path + how to launch.
#
# Usage:
#   ./install.sh            # if running, abort and tell the user to quit it
#   ./install.sh --quit     # if running, quit it automatically, then install
set -e

HERE="${0:A:h}"                 # app/packaging
APP="${HERE:h}"                 # app
SRC="$APP/dist/Market.app"
DEST_DIR="/Applications"
DEST="$DEST_DIR/Market.app"
QUIT=0
[[ "${1:-}" == "--quit" ]] && QUIT=1

[[ -d "$SRC" ]] || { echo "no built bundle at $SRC — run build-app.sh first" >&2; exit 1; }

mkdir -p "$DEST_DIR"

# --- running-app detection (match the installed bundle path) ---
RUNNING=$(pgrep -f "$DEST/Contents/MacOS/Market" || true)
if [[ -n "$RUNNING" ]]; then
  echo "Market is running (pid: $RUNNING)."
  if [[ "$QUIT" == "1" ]]; then
    echo "==> quitting running Market"
    osascript -e 'quit app "Market"' >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f "$DEST/Contents/MacOS/Market" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if pgrep -f "$DEST/Contents/MacOS/Market" >/dev/null 2>&1; then
      echo "==> still running; force-quitting"
      pkill -f "$DEST/Contents/MacOS/Market" || true
      sleep 1
    fi
  else
    echo "Refusing to overwrite a running app. Quit Market and re-run, or pass --quit." >&2
    exit 2
  fi
fi

# --- back up prior bundle ---
if [[ -d "$DEST" ]]; then
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  BACKUP="$DEST_DIR/Market.app.bak-$TS"
  echo "==> backing up prior bundle -> $BACKUP"
  rm -rf "$BACKUP"
  cp -R "$DEST" "$BACKUP"
fi

# --- install (atomic-ish: stage to temp then swap) ---
echo "==> installing -> $DEST"
STAGE="$DEST_DIR/.Market.app.stage-$$"
rm -rf "$STAGE"
cp -R "$SRC" "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"

# --- verify installed signature ---
echo "==> verifying installed signature"
codesign --verify --verbose "$DEST"

echo
echo "installed: $DEST"
echo "launch:    open \"$DEST\"   (or click Market in /Applications / Spotlight)"
