#!/usr/bin/env python3
"""Focused checks for bounded per-entry registry health timeouts."""

from __future__ import annotations

import importlib.util
import ast
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCANNER = ROOT / "scripts/tool-status-scan.py"
REGISTER = ROOT / "scripts/tool-status-register"
WORKER = ROOT / "scripts/tool-status-repair-worker.py"


def load_scanner():
    spec = importlib.util.spec_from_file_location("tool_status_scan_timeout_test", SCANNER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tool-status-registry-timeout-") as temporary:
        root = Path(temporary)
        local_bin = root / ".local/bin"
        state = root / "state"
        local_bin.mkdir(parents=True)
        state.mkdir()

        binary = local_bin / "slow-check"
        binary.write_text("#!/bin/sh\nprintf 'slow-check 1.0\\n'\n", encoding="utf-8")
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR)

        env = {
            **os.environ,
            "HOME": str(root),
            "TOOL_STATUS_STATE": str(state),
        }
        registered = subprocess.run(
            ["/usr/bin/python3", str(REGISTER), "add", "slow-check", "--check", "version", "--timeout", "15"],
            env=env, text=True, capture_output=True,
        )
        assert registered.returncode == 0, registered.stderr
        entry = json.loads((state / "registry.json").read_text())["tools"][0]
        assert entry["timeoutSeconds"] == 15

        preserved = subprocess.run(
            ["/usr/bin/python3", str(REGISTER), "add", "slow-check", "--check", "version"],
            env=env, text=True, capture_output=True,
        )
        assert preserved.returncode == 0, preserved.stderr
        entry = json.loads((state / "registry.json").read_text())["tools"][0]
        assert entry["timeoutSeconds"] == 15, "an update without --timeout discarded the contract"

        for value in ("4", "31"):
            rejected = subprocess.run(
                ["/usr/bin/python3", str(REGISTER), "add", "slow-check", "--timeout", value],
                env=env, text=True, capture_output=True,
            )
            assert rejected.returncode == 2
        rejected_exists = subprocess.run(
            [
                "/usr/bin/python3", str(REGISTER), "add", "slow-check",
                "--check", "exists", "--timeout", "15",
            ],
            env=env, text=True, capture_output=True,
        )
        assert rejected_exists.returncode == 2

        scanner = load_scanner()
        scanner.REGISTRY = state / "registry.json"
        scanner.LOCAL_BIN = local_bin
        scanner.PATH = f"{local_bin}:/usr/bin:/bin"
        seen_timeouts: list[int] = []

        def fake_run(command: list[str], timeout: int = 8) -> tuple[int, str]:
            seen_timeouts.append(timeout)
            return 0, "slow-check 1.0"

        scanner.run = fake_run
        scanner.time.time = lambda: 0.0
        rows: list[dict] = []
        scanner.registry_records(rows)
        assert seen_timeouts == [15]
        assert any(row["name"] == "slow-check" and row["state"] == "ok" for row in rows)

        tools = []
        for index in range(7):
            name = f"slow-{index}"
            path = local_bin / name
            path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
            tools.append({
                "name": name, "binary": name, "check": "version",
                "addedBy": "agent", "timeoutSeconds": 15,
            })
        scanner.REGISTRY.write_text(json.dumps({"schemaVersion": 1, "tools": tools}))
        seen_timeouts.clear()
        rows.clear()
        clock = [0.0]

        def worst_case_run(command: list[str], timeout: int = 8) -> tuple[int, str]:
            seen_timeouts.append(timeout)
            clock[0] += timeout
            if command[0] == "slow-2":
                return 9, "fixture failure"
            return 0, "slow-check 1.0"

        scanner.run = worst_case_run
        scanner.time.monotonic = lambda: clock[0]
        scanner.registry_records(rows)
        assert seen_timeouts == [15] * 6, "registry timeout ceiling exceeded 90 seconds"
        slow_rows = [row for row in rows if row["name"].startswith("slow-")]
        assert sum(row["state"] == "ok" for row in slow_rows) == 5
        assert next(row for row in slow_rows if row["name"] == "slow-2")["state"] == "warn"
        assert sum(row["state"] == "unknown" for row in slow_rows) == 1
        assert slow_rows[-1]["name"] == "slow-6", "registry budget ordering became nondeterministic"
        assert slow_rows[-1]["headline"] == "Health check deferred by scan budget"
        first_deferred = slow_rows[-1]["name"]

        clock[0] = 0.0
        seen_timeouts.clear()
        rows.clear()
        scanner.time.time = lambda: 300.0
        scanner.registry_records(rows)
        slow_rows_second = [row for row in rows if row["name"].startswith("slow-")]
        deferred_second = next(row for row in slow_rows_second if row["state"] == "unknown")
        assert deferred_second["name"] != first_deferred, "the same registry entry starved across scans"
        budget_evidence = (
            "ceiling evidence: 7 entries x 15s, executed 6; "
            f"first deferred {first_deferred}, next deferred {deferred_second['name']}; "
            "failing probe remained warn"
        )

        tools[0]["timeoutSeconds"] = 31
        scanner.REGISTRY.write_text(json.dumps({"schemaVersion": 1, "tools": tools}))
        rows.clear()
        scanner.registry_records(rows)
        invalid = next(row for row in rows if row["name"] == "Tool Registry entries")
        assert "timeoutSeconds=31" in invalid["detail"]

        sleeper = local_bin / "sleepy-check"
        sleeper.write_text("#!/bin/sh\nsleep 6\nprintf 'sleepy-check 1.0\\n'\n", encoding="utf-8")
        sleeper.chmod(sleeper.stat().st_mode | stat.S_IXUSR)
        scanner = load_scanner()
        scanner.REGISTRY = state / "registry.json"
        scanner.LOCAL_BIN = local_bin
        scanner.PATH = f"{local_bin}:/usr/bin:/bin"
        scanner.REGISTRY.write_text(json.dumps({"schemaVersion": 1, "tools": [{
            "name": "sleepy-check", "binary": "sleepy-check", "check": "version",
            "addedBy": "agent", "timeoutSeconds": 15,
        }]}))
        rows.clear()
        scanner.registry_records(rows)
        assert rows[0]["state"] == "ok", "a >5s check did not complete under its 15s contract"

        tree = ast.parse(WORKER.read_text(encoding="utf-8"))
        success_calls = [
            node for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "finish_success"
        ]
        # Pinned so a new success path cannot be added without someone confirming
        # it names an outcome. The v5 issue-authority lane adds two explicit
        # trusted-health resolution paths to the ten pre-existing outcomes, and
        # the "needs_ivo" drain adds the thirteenth: a row recording a past event
        # that no agent can repair leaves the queue instead of retrying forever.
        assert len(success_calls) == 13
        assert all(len(node.args) == 5 for node in success_calls), "a success call lacks explicit outcome"

    print("registry timeout checks passed")
    print(budget_evidence)
    print("timing evidence: a real 6s --version probe passed under timeoutSeconds=15")
    print(f"attribution evidence: {len(success_calls)} finish_success call sites require explicit outcome (including two issue-authority and two staged-candidate paths)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
