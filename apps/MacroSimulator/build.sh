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
# The bundle is signed with the "Ivo Market Dev" certificate like the rest of the
# fleet, so its permissions survive rebuilds.
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
# Certificate, not ad-hoc: an ad-hoc signature is keyed to the exact compiled bytes,
# so every rebuild looks like a different app to macOS and silently drops its
# permissions. Check the fleet with `signing-audit`.
if security find-identity -v -p codesigning | grep -q "Ivo Market Dev"; then
  codesign --force --deep -s "Ivo Market Dev" --timestamp=none "$APP"
else
  echo "WARNING: 'Ivo Market Dev' certificate missing; ad-hoc signing means permissions break on rebuild." >&2
  codesign --force --deep -s - "$APP"
fi
echo "Deployed to $APP"
