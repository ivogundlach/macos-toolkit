#!/bin/sh
# Compatibility entrypoint; all behavior lives in yt_fetch.py.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${YT_FETCH_PYTHON:-}" ]; then
  PYTHON=$YT_FETCH_PYTHON
elif [ -x /usr/bin/python3 ]; then
  PYTHON=/usr/bin/python3
else
  PYTHON=$(command -v python3 || true)
fi

if [ -z "${PYTHON:-}" ]; then
  echo "ERROR: Python 3.9+ was not found. Set YT_FETCH_PYTHON to a supported interpreter." >&2
  exit 3
fi

if ! "$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "ERROR: yt-dlp-fetch requires Python 3.9+. Set YT_FETCH_PYTHON and retry." >&2
  exit 3
fi

exec "$PYTHON" "$SCRIPT_DIR/yt_fetch.py" "$@"
