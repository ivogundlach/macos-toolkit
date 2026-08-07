#!/usr/bin/env bash
set -euo pipefail

CLIENT_SECRET="$HOME/.config/gws/client_secret.json"

if [[ ! -f "$CLIENT_SECRET" ]]; then
  echo "Missing: $CLIENT_SECRET" >&2
  echo "Download the Desktop OAuth client JSON from Google Cloud Console and save it there." >&2
  exit 1
fi

exec gws auth login --readonly --services gmail,drive,docs,sheets,calendar,keep,people,tasks
