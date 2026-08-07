#!/usr/bin/env python3
# SOURCE OF TRUTH. build.sh copies this file into
# "/Applications/Tool Dashboard.app" (or ~/.local/bin). The deployed copy is a
# build artifact: edit THIS file, then run Projects/ToolStatusDashboard/build.sh.
# Editing the deployed copy, or editing here without rebuilding, makes the dashboard
# report stale findings. The "Deployed source drift" check flags that divergence.
"""Queue external failures for repair; deliver pushes only for repair escalation."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path


APP = Path(os.environ.get(
    "TOOL_STATUS_NOTIFICATION_APP",
    "/Applications/Tool Dashboard.app/Contents/MacOS/ToolStatusDashboard",
))
STATE = Path(os.environ.get(
    "TOOL_STATUS_STATE",
    Path.home() / ".local/state/tool-status-dashboard",
))
QUEUE = STATE / "repair-queue"


def iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
        temporary = Path(handle.name)
    os.replace(temporary, path)


def queue_repair(tool_name: str, cause: str, group: str) -> int:
    incident_id = f"External:{tool_name}"
    fingerprint = hashlib.sha256(f"{incident_id}|{cause}".encode("utf-8")).hexdigest()[:24]
    key = hashlib.sha256(f"{incident_id}|{fingerprint}".encode("utf-8")).hexdigest()[:24]
    created = iso()
    job = {
        "schemaVersion": 1,
        "id": incident_id,
        "fingerprint": fingerprint,
        "createdAt": created,
        "attempts": 0,
        "nextAttemptAt": created,
        "externalGroup": group,
        "item": {
            "id": incident_id,
            "name": tool_name,
            "category": "Background Job",
            "state": "fail",
            "headline": cause,
            "detail": cause,
            "evidence": "External Tool Dashboard producer",
            "checkedAt": created,
            "fix": None,
            "causeCode": "external.failure",
            "causeParams": {},
            "notificationPolicy": "immediate",
            "deadlineAt": None,
        },
    }
    path = QUEUE / f"{key}.json"
    if not path.exists():
        atomic_json(path, job)
    if os.environ.get("TOOL_STATUS_NO_KICKSTART") != "1":
        try:
            subprocess.run(
                ["/bin/launchctl", "kickstart", f"gui/{os.getuid()}/com.ivogundlach.tool-status-dashboard.repair"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=3, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            # The durable queue is authoritative; launchd's 60-second interval
            # will pick it up even when an immediate kickstart is unavailable.
            pass
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--deliver", action="store_true", help="Internal: deliver an escalated repair push")
    parser.add_argument("tool_name")
    parser.add_argument("cause")
    parser.add_argument("--group")
    args = parser.parse_args()
    group = args.group or "external." + hashlib.sha256(
        f"{args.tool_name}\0{args.cause}".encode("utf-8")
    ).hexdigest()[:24]
    if not args.deliver:
        return queue_repair(args.tool_name, args.cause, group)
    if os.environ.get("TOOL_STATUS_NOTIFICATION_DRY_RUN") == "1":
        path = Path(os.environ.get(
            "TOOL_STATUS_NOTIFICATION_LOG",
            STATE / "notification-dry-run.jsonl",
        ))
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "title": args.tool_name, "body": args.cause, "group": group,
            }, separators=(",", ":")) + "\n")
        return 0
    if not os.access(APP, os.X_OK):
        return 127
    try:
        result = subprocess.run(
            [str(APP), "--notify", args.tool_name, args.cause, f"tool-status-dashboard.{group}"],
            stdin=subprocess.DEVNULL,
            timeout=20,
            check=False,
        )
        return result.returncode
    except (OSError, subprocess.TimeoutExpired):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
