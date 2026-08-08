#!/bin/bash
# Build MacroSimulator and deploy it into /Applications/Tax Simulator.app.
# Set NO_DEPLOY=1 to compile only.
#
# swiftc, not `swift build`: Package.swift declares swift-tools-version 6.0, so
# SwiftPM compiles under Swift 6 strict concurrency and three pre-existing
# `sending 'self' risks causing data races` errors in Views/AgyChat.swift become
# hard errors. Swift 5 language mode keeps them warnings. Fixing the actor
# isolation properly would let this move to real Swift 6 mode.
#
# The bundle is adhoc-signed, unlike the rest of the fleet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Tax Simulator.app"
OUT="$ROOT/MacroSimulatorApp"

cd "$ROOT"
echo "Compiling…"
swiftc -swift-version 5 -O $(find Sources -name '*.swift') -o "$OUT"
echo "Built $OUT"

if [ "${NO_DEPLOY:-0}" = "1" ]; then
  echo "NO_DEPLOY=1 — not deploying."
  exit 0
fi

[ -d "$APP" ] || { echo "Missing $APP — nothing to deploy into." >&2; exit 1; }
cp "$OUT" "$APP/Contents/MacOS/MacroSimulator"
codesign --force --deep -s - "$APP"
echo "Deployed to $APP"
