#!/usr/bin/env python3
"""Enable and load one exact first-party LaunchAgent after a user click."""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


ALLOWED_LABEL = re.compile(r"^com\.(?:ivogundlach|ivo|user)\.[A-Za-z0-9._-]+$")


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False)


def main() -> int:
    if len(sys.argv) != 2 or not ALLOWED_LABEL.fullmatch(sys.argv[1]):
        print("This action did not name one valid first-party background job.", file=sys.stderr)
        return 2
    label = sys.argv[1]
    home = Path(os.environ.get("TOOL_STATUS_HOME", str(Path.home()))).resolve()
    plist = home / "Library" / "LaunchAgents" / f"{label}.plist"
    try:
        data = plistlib.loads(plist.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        print("The background job definition is missing or invalid.", file=sys.stderr)
        return 2
    if not isinstance(data, dict) or data.get("Label") != label:
        print("The background job definition does not match the requested job.", file=sys.stderr)
        return 2

    launchctl = os.environ.get("TOOL_STATUS_LAUNCHCTL", "/bin/launchctl")
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{label}"
    enabled = run([launchctl, "enable", target])
    if enabled.returncode != 0:
        print("macOS did not allow this background job to be enabled.", file=sys.stderr)
        return 1
    loaded = run([launchctl, "bootstrap", domain, str(plist)])
    verified = run([launchctl, "print", target])
    if verified.returncode == 0:
        return 0

    # Preserve the prior disabled state if loading did not succeed.
    run([launchctl, "disable", target])
    print("The job could not be loaded, so it was returned to its disabled state.", file=sys.stderr)
    return loaded.returncode or 1


if __name__ == "__main__":
    raise SystemExit(main())
