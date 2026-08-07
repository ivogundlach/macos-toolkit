#!/bin/zsh
# setup-swiftpm-toolfix.sh
#
# Works around a packaging defect in this Command Line Tools (CLT) install:
# `swift build` (the `swift-package` multitool) is missing an rpath, so it fails
# to load `BuildServerProtocol.framework` (and the SWB* plugin frameworks) even
# though they ship inside the toolchain. The frameworks live under
#   /Library/Developer/CommandLineTools/usr/lib/swift/pm/
# and inside SwiftBuild.framework's plugin bundle, but `swift-package`'s embedded
# rpaths never reach them. Those toolchain dirs are read-only (SIP) and DYLD_*
# env vars are stripped for binaries on SIP-protected paths, so we cannot patch
# in place or inject a search path.
#
# Fix: make a *copy* of swift-package in a user-writable mirror whose `../lib`
# resolves back to the real CLT lib (so @executable_path-relative rpaths still
# work), collect every toolchain framework it needs into one directory via
# symlinks, add a SINGLE absolute rpath to that directory (one rpath fits within
# the binary's header padding), and ad-hoc re-sign the copy. Symlinks named
# swift-build / swift-run / swift-test select the verb via argv[0].
#
# Idempotent: safe to re-run. The mirror is tiny (symlinks only).
set -e

CLT=/Library/Developer/CommandLineTools
PM="$CLT/usr/lib/swift/pm"
SWBFW="$PM/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/Frameworks"
HERE="${0:A:h}"
APP="${HERE:h}"                 # app/ dir
W="$APP/.toolfix"

if [[ ! -e "$CLT/usr/bin/swift-package" ]]; then
  echo "error: swift-package not found under $CLT — is CLT installed?" >&2
  exit 1
fi

# If swift-package already works as-is (e.g. fixed in a future CLT), skip.
if "$CLT/usr/bin/swift-package" --version >/dev/null 2>&1; then
  echo "system swift-package works; no toolfix needed."
  # Remove any stale mirror; build.sh falls back to the system `swift build`.
  # A symlinked swift-package resolves its resource dirs relative to the mirror,
  # so it can't find PackageDescription there — don't leave a broken alias behind.
  rm -rf "$W"
  exit 0
fi

echo "patching swift-package (CLT rpath defect) -> $W"
rm -rf "$W"
mkdir -p "$W/usr/bin" "$W/fw"
ln -s "$CLT/usr/lib" "$W/usr/lib"     # so @executable_path/../lib resolves

# Consolidate every toolchain framework the tool may dlopen via @rpath.
for fwdir in "$PM" "$SWBFW"; do
  [[ -d "$fwdir" ]] || continue
  for f in "$fwdir"/*.framework(N); do
    ln -sf "$f" "$W/fw/${f:t}"
  done
done

cp "$CLT/usr/bin/swift-package" "$W/usr/bin/swift-package"
chmod u+w "$W/usr/bin/swift-package"
install_name_tool -add_rpath "$W/fw" "$W/usr/bin/swift-package" 2>&1 | grep -v invalidate || true
codesign -s - -f "$W/usr/bin/swift-package" >/dev/null 2>&1

ln -sf swift-package "$W/usr/bin/swift-build"
ln -sf swift-package "$W/usr/bin/swift-run"
ln -sf swift-package "$W/usr/bin/swift-test"

echo "verifying:"
"$W/usr/bin/swift-package" --version
echo "toolfix ready: $W/usr/bin/swift-build"
