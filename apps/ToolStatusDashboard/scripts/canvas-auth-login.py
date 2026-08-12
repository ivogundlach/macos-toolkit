#!/usr/bin/python3
"""Complete Canvas sign-in, rebuild the School snapshot, and verify it."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def run(command: list[str], cwd: Path, timeout: int) -> int:
    try:
        completed = subprocess.run(command, cwd=cwd, timeout=timeout, check=False)
        return completed.returncode
    except subprocess.TimeoutExpired:
        print("The step did not finish in time.", file=sys.stderr)
        return 124
    except OSError as error:
        print(f"Could not start the required School step: {error}", file=sys.stderr)
        return 127


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sync-dir", required=True)
    parser.add_argument(
        "--snapshot",
        default=str(Path.home() / ".local/state/school-dashboard/dashboard.json"),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sync_dir = Path(args.sync_dir).expanduser().resolve()
    python = sync_dir / ".venv/bin/python"
    setup = sync_dir / "setup_session.py"
    exporter = sync_dir / "school_sync.py"
    if not all(path.is_file() for path in (python, setup, exporter)):
        print("The School sign-in tools are unavailable.", file=sys.stderr)
        return 127

    print("— Log in to Canvas —", flush=True)
    setup_rc = run([str(python), str(setup)], sync_dir, timeout=12 * 60)
    if setup_rc != 0:
        return setup_rc

    print("\nRefreshing the School dashboard with the new Canvas session…", flush=True)
    export_rc = run([str(python), str(exporter), "export"], sync_dir, timeout=5 * 60)
    if export_rc != 0:
        print("Canvas sign-in succeeded, but the School dashboard refresh failed.", file=sys.stderr)
        return export_rc

    snapshot = Path(args.snapshot).expanduser()
    try:
        payload = json.loads(snapshot.read_text(encoding="utf-8"))
        session = (payload.get("health") or {}).get("canvas_session") or {}
    except (OSError, ValueError, TypeError) as error:
        print(f"The refreshed School dashboard could not be verified: {error}", file=sys.stderr)
        return 65
    if not session.get("ok"):
        print("Canvas accepted the browser sign-in, but the refreshed School check still reports an expired session.", file=sys.stderr)
        return 1

    print("Canvas login and School dashboard refresh completed.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
