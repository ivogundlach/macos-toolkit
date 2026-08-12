#!/usr/bin/env python3
"""Checks deployment-interruption suppression without masking later failures."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path


WRAPPER = Path(__file__).with_name("tool-status-background-scan-wrapper.sh")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tool-status-wrapper-test-") as temporary:
        root = Path(temporary)
        state = root / "state"
        runner = root / "runner"
        runner.write_text("#!/bin/bash\nexit \"${FAKE_RUNNER_RC:-143}\"\n", encoding="utf-8")
        runner.chmod(0o755)
        env = {
            **os.environ,
            "TOOL_STATUS_STATE": str(state),
            "TOOL_STATUS_BACKGROUND_RUNNER": str(runner),
        }

        def invoke(rc: int = 143) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                ["/bin/bash", str(WRAPPER)],
                env={**env, "FAKE_RUNNER_RC": str(rc)}, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )

        absent = invoke()
        assert absent.returncode == 143
        assert json.loads((state / "wrapper-failure.json").read_text())["cause"]

        (state / "wrapper-failure.json").unlink()
        marker = state / "deployment-in-progress.json"
        marker.write_text("{}\n", encoding="utf-8")
        old = time.time() - 3600
        os.utime(marker, (old, old))
        stale = invoke()
        assert stale.returncode == 143 and (state / "wrapper-failure.json").exists()

        (state / "wrapper-failure.json").unlink()
        marker.write_text("{}\n", encoding="utf-8")
        fresh = invoke()
        assert fresh.returncode == 0 and not (state / "wrapper-failure.json").exists()

        ordinary = invoke(1)
        assert ordinary.returncode == 1 and (state / "wrapper-failure.json").exists()

    print("background scan wrapper marker checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
