#!/bin/zsh
# build.sh [debug|release]  — builds the Market SwiftPM package with CLT only.
#
# Wraps `swift build` so the build works around the CLT swift-package rpath
# defect (see setup-swiftpm-toolfix.sh). If the system `swift build` is fixed in
# a future CLT, this still works (the toolfix becomes a thin alias).
#
# Usage:
#   ./scripts/build.sh            # debug build  -> .build/debug/Market
#   ./scripts/build.sh release    # release build -> .build/release/Market
set -e

HERE="${0:A:h}"
APP="${HERE:h}"
CFG="${1:-debug}"

# Ensure the toolfix exists / is current (no-op when the system toolchain works).
"$HERE/setup-swiftpm-toolfix.sh" >/dev/null

# Prefer the toolfix shim when present; otherwise the system CLT swift works.
if [[ -x "$APP/.toolfix/usr/bin/swift-build" ]]; then
  SWIFT_BUILD=("$APP/.toolfix/usr/bin/swift-build")
else
  SWIFT_BUILD=(swift build)
fi

cd "$APP"
if [[ "$CFG" == "release" ]]; then
  "${SWIFT_BUILD[@]}" -c release --product Market
  echo "binary: $APP/.build/release/Market"
else
  "${SWIFT_BUILD[@]}" --product Market
  echo "binary: $APP/.build/debug/Market"
fi
