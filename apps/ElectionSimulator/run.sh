#!/bin/bash
# Build (if needed) and launch Psephos.
set -euo pipefail
cd "$(dirname "$0")"
[ -d "build/Psephos.app" ] || ./build.sh
open "build/Psephos.app"
