#!/usr/bin/env python3
"""Checks Canvas login ordering and post-login School snapshot verification."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


HELPER = Path(__file__).with_name("canvas-auth-login.py")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="canvas-auth-login-test-") as temporary:
        root = Path(temporary)
        sync = root / "sync"
        python = sync / ".venv/bin/python"
        python.parent.mkdir(parents=True)
        (sync / "setup_session.py").write_text("# fixture\n", encoding="utf-8")
        (sync / "school_sync.py").write_text("# fixture\n", encoding="utf-8")
        python.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
mode=os.environ.get("FAKE_CANVAS_MODE", "success")
step=Path(sys.argv[1]).name
log=Path(os.environ["FAKE_CANVAS_LOG"])
steps=json.loads(log.read_text()) if log.exists() else []
steps.append(step)
log.write_text(json.dumps(steps))
if step == "setup_session.py" and mode == "setup-fail": raise SystemExit(4)
if step == "school_sync.py":
    if mode == "export-fail": raise SystemExit(5)
    snapshot=Path(os.environ["FAKE_CANVAS_SNAPSHOT"])
    if mode == "invalid-json": snapshot.write_text("{bad")
    else: snapshot.write_text(json.dumps({"health":{"canvas_session":{"ok": mode != "expired"}}}))
raise SystemExit(0)
""", encoding="utf-8")
        python.chmod(0o755)
        snapshot = root / "dashboard.json"
        log = root / "steps.json"
        base_env = {
            **os.environ,
            "FAKE_CANVAS_LOG": str(log),
            "FAKE_CANVAS_SNAPSHOT": str(snapshot),
        }

        def invoke(mode: str) -> subprocess.CompletedProcess[str]:
            log.unlink(missing_ok=True)
            snapshot.unlink(missing_ok=True)
            return subprocess.run(
                ["/usr/bin/python3", str(HELPER), "--sync-dir", str(sync), "--snapshot", str(snapshot)],
                env={**base_env, "FAKE_CANVAS_MODE": mode}, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )

        success = invoke("success")
        assert success.returncode == 0
        assert json.loads(log.read_text()) == ["setup_session.py", "school_sync.py"]

        setup_failed = invoke("setup-fail")
        assert setup_failed.returncode == 4
        assert json.loads(log.read_text()) == ["setup_session.py"]

        export_failed = invoke("export-fail")
        assert export_failed.returncode == 5
        assert json.loads(log.read_text()) == ["setup_session.py", "school_sync.py"]

        invalid = invoke("invalid-json")
        assert invalid.returncode == 65

        expired = invoke("expired")
        assert expired.returncode == 1
        assert "expired session" in expired.stderr

    print("Canvas login and snapshot verification checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
