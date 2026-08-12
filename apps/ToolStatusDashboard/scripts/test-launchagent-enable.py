#!/usr/bin/env python3
"""Checks the exact enable/load action and its rollback behavior."""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


HELPER = Path(__file__).with_name("launchagent-enable.py")
LABEL = "com.ivogundlach.fixture-job"


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="launchagent-enable-test-") as temporary:
        root = Path(temporary)
        agents = root / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        (agents / f"{LABEL}.plist").write_bytes(plistlib.dumps({
            "Label": LABEL,
            "ProgramArguments": ["/bin/true"],
        }))
        fake = root / "launchctl"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
log=Path(os.environ["FAKE_LAUNCHCTL_LOG"])
calls=json.loads(log.read_text()) if log.exists() else []
calls.append(sys.argv[1:])
log.write_text(json.dumps(calls))
verb=sys.argv[1] if len(sys.argv)>1 else ""
if verb == "print":
    raise SystemExit(0 if os.environ.get("FAKE_LAUNCHCTL_MODE") == "success" else 3)
if verb == "bootstrap" and os.environ.get("FAKE_LAUNCHCTL_MODE") != "success":
    raise SystemExit(5)
raise SystemExit(0)
""", encoding="utf-8")
        fake.chmod(0o755)
        log = root / "calls.json"
        base_env = {
            **os.environ,
            "TOOL_STATUS_HOME": str(root),
            "TOOL_STATUS_LAUNCHCTL": str(fake),
            "FAKE_LAUNCHCTL_LOG": str(log),
        }

        success = subprocess.run(
            ["/usr/bin/python3", str(HELPER), LABEL],
            env={**base_env, "FAKE_LAUNCHCTL_MODE": "success"}, check=False,
        )
        assert success.returncode == 0
        calls = json.loads(log.read_text())
        assert [call[0] for call in calls] == ["enable", "bootstrap", "print"]

        log.unlink()
        failed = subprocess.run(
            ["/usr/bin/python3", str(HELPER), LABEL],
            env={**base_env, "FAKE_LAUNCHCTL_MODE": "fail"}, check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        assert failed.returncode != 0
        calls = json.loads(log.read_text())
        assert [call[0] for call in calls] == ["enable", "bootstrap", "print", "disable"]

        log.unlink()
        invalid = subprocess.run(
            ["/usr/bin/python3", str(HELPER), "org.example.foreign"],
            env=base_env, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        assert invalid.returncode == 2 and not log.exists()

    print("LaunchAgent enable/load checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
