#!/usr/bin/env python3
"""Checks that manual LaunchAgents stay quiet and disabled schedules require a choice."""

from __future__ import annotations

import importlib.util
import plistlib
import tempfile
from pathlib import Path


SCANNER = Path(__file__).with_name("tool-status-scan.py")


def main() -> int:
    spec = importlib.util.spec_from_file_location("tool_status_launchagent_test", SCANNER)
    assert spec and spec.loader
    scanner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scanner)

    with tempfile.TemporaryDirectory(prefix="tool-status-launchagent-test-") as temporary:
        scanner.HOME = Path(temporary)
        scanner.RESOURCE_DIR = SCANNER.parent
        agents = scanner.HOME / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        manual_label = "com.ivogundlach.manual-fixture"
        scheduled_label = "com.ivogundlach.scheduled-fixture"
        archive_label = "com.ivogundlach.app-repo-sync"
        protected_label = "com.ivogundlach.protected-fixture"
        (agents / f"{manual_label}.plist").write_bytes(plistlib.dumps({
            "Label": manual_label,
            "ProgramArguments": ["/usr/bin/true"],
            "RunAtLoad": False,
        }))
        (agents / f"{scheduled_label}.plist").write_bytes(plistlib.dumps({
            "Label": scheduled_label,
            "ProgramArguments": ["/usr/bin/true"],
            "StartInterval": 300,
        }))
        (agents / f"{archive_label}.plist").write_bytes(plistlib.dumps({
            "Label": archive_label,
            "ProgramArguments": ["/usr/bin/true"],
            "StartInterval": 300,
        }))
        protected_runner = scanner.HOME / ".memory/tools/protected-fixture.py"
        protected_runner.parent.mkdir(parents=True)
        protected_runner.write_text("# fixture\n", encoding="utf-8")
        (agents / f"{protected_label}.plist").write_bytes(plistlib.dumps({
            "Label": protected_label,
            "ProgramArguments": ["/usr/bin/python3", str(protected_runner)],
            "StartInterval": 300,
        }))
        archive_status = scanner.HOME / ".local/state/app-repo-sync/status.tsv"
        archive_status.parent.mkdir(parents=True)
        archive_status.write_text(
            "last_result\tpartial\nlast_detail\t20 apps checked but 1 still have unsaved work\n",
            encoding="utf-8",
        )

        def fake_run(command: list[str], timeout: int = 0, cwd: Path | None = None):
            if command[1:2] == ["print-disabled"]:
                return 0, (
                    'disabled services = {\n'
                    f'"{manual_label}" => disabled\n'
                    f'"{scheduled_label}" => disabled\n'
                    '}\n'
                )
            if archive_label in command[-1]:
                return 0, "state = exited\nlast exit code = 1\nruns = 2\n"
            return 113, "Could not find service"

        scanner.run = fake_run
        rows: list[dict] = []
        scanner.launch_agent_records(rows)
        manual = next(row for row in rows if row["name"] == manual_label)
        scheduled = next(row for row in rows if row["name"] == scheduled_label)
        archive = next(row for row in rows if row["name"] == archive_label)
        protected = next(row for row in rows if row["name"] == protected_label)
        assert manual["state"] == "ok" and manual["headline"] == "Available for manual use"
        assert manual["fix"] is None and manual["causeCode"] is None
        assert scheduled["state"] == "fail" and scheduled["headline"] == "Disabled"
        assert scheduled["causeCode"] == "launchagent.disabled"
        assert scheduled["fix"]["kind"] == "launch" and scheduled["fix"]["label"] == "Enable and load"
        assert archive["state"] == "warn" and archive["selfHealing"] is True
        assert archive["headline"] == "Waiting for current project work to finish"
        assert archive["fix"] is None and archive["causeCode"] == "app_repo_sync.active_changes"
        assert protected["state"] == "warn" and protected["causeCode"] == "launchagent.protected_not_loaded"
        assert protected["fix"]["kind"] == "launch" and protected["fix"]["label"] == "Approve and load protected job"

    print("LaunchAgent classification checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
