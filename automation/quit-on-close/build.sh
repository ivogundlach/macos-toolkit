#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
destination="$HOME/.local/bin/quit-on-close"
agent="$HOME/Library/LaunchAgents/com.ivogundlach.quit-on-close.plist"
domain="gui/$(id -u)"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc -O \
    "$project_dir/main.swift" \
    -o "$build_dir/quit-on-close"

codesign --force --sign "Ivo Market Dev" \
    --identifier com.ivogundlach.quit-on-close \
    "$build_dir/quit-on-close"

mkdir -p "${destination:h}"
launchctl bootout "$domain/com.ivogundlach.quit-on-close" 2>/dev/null || true
mv "$build_dir/quit-on-close" "$destination"
launchctl bootstrap "$domain" "$agent"
echo "installed $destination"
