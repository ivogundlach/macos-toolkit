#!/usr/bin/env python3
"""One disposable end-to-end acceptance test against real Luna/max."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
WORKER = Path(os.environ.get(
    "TOOL_STATUS_TEST_WORKER", HERE / "tool-status-repair-worker.py",
))
SCHEMA = HERE / "tool-status-repair-result.schema.json"
DECISION_SCHEMA = HERE / "tool-status-repair-decision.schema.json"
CANONICAL_HOME = Path.home()
CODEX = CANONICAL_HOME / ".local/bin/codex"


def executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def main() -> int:
    if not CODEX.is_file():
        raise SystemExit(f"Codex CLI is unavailable at {CODEX}")

    with tempfile.TemporaryDirectory(prefix="tool-status-live-luna-") as temporary:
        root = Path(temporary)
        home = root / "home"
        state = root / "state"
        project = home / "Projects/UsageQueue"
        queue = state / "repair-queue"
        project.mkdir(parents=True)
        queue.mkdir(parents=True)
        target = project / "config.py"
        target.write_text(
            '"""Disposable repair fixture."""\n\nEXPECTED_TOTAL = 4\nACTUAL_TOTAL = 3\n',
            encoding="utf-8",
        )
        contract = project / "tests/test_total_contract.py"
        contract.parent.mkdir()
        contract.write_text(
            "assert ACTUAL_TOTAL == EXPECTED_TOTAL == 4\n",
            encoding="utf-8",
        )
        scanner = root / "scanner.py"
        executable(scanner, f"""#!/usr/bin/env python3
import json
from pathlib import Path
target = Path({str(target)!r})
namespace = {{}}
exec(target.read_text(encoding="utf-8"), namespace)
healthy = namespace.get("ACTUAL_TOTAL") == namespace.get("EXPECTED_TOTAL") == 4
item = {{
    "id": "Background Job:UsageQueue",
    "name": "UsageQueue",
    "category": "Background Job",
    "state": "ok" if healthy else "fail",
    "headline": "Fixture total is correct" if healthy else "Fixture total is wrong",
    "detail": "The configuration declares EXPECTED_TOTAL = 4 but ACTUAL_TOTAL = 3. "
              "Repair config.py so both totals equal 4.",
    "evidence": str(target),
    "checkedAt": "2026-07-31T00:00:00+00:00",
    "fix": None,
    "causeCode": "usagequeue.fixture_total_mismatch",
    "causeParams": {{}},
    "notificationPolicy": "immediate",
    "deadlineAt": None,
}}
print(json.dumps({{
    "schemaVersion": 2,
    "generatedAt": "2026-07-31T00:00:00+00:00",
    "liveAuth": False,
    "items": [item],
}}))
""")
        job = {
            "schemaVersion": 1,
            "id": "Background Job:UsageQueue",
            "fingerprint": "live-luna-max-disposable-v1",
            "createdAt": "2026-07-31T00:00:00+00:00",
            "attempts": 0,
            "nextAttemptAt": "2026-07-31T00:00:00+00:00",
            "item": {
                "id": "Background Job:UsageQueue",
                "name": "UsageQueue",
                "category": "Background Job",
                "state": "fail",
                "headline": "Fixture total is wrong",
                "detail": (
                    "The configuration declares EXPECTED_TOTAL = 4 but "
                    "ACTUAL_TOTAL = 3. Repair config.py so both totals equal 4."
                ),
                "evidence": str(target),
                "checkedAt": "2026-07-31T00:00:00+00:00",
                "fix": None,
                "causeCode": "usagequeue.fixture_total_mismatch",
                "causeParams": {},
                "notificationPolicy": "immediate",
                "deadlineAt": None,
            },
        }
        (queue / "fixture.json").write_text(json.dumps(job), encoding="utf-8")
        environment = {
            **os.environ,
            "TOOL_STATUS_HOME": str(home),
            "TOOL_STATUS_STATE": str(state),
            "TOOL_STATUS_SCANNER": str(scanner),
            "TOOL_STATUS_CODEX": str(CODEX),
            "TOOL_STATUS_REPAIR_SCHEMA": str(SCHEMA),
            "TOOL_STATUS_DECISION_SCHEMA": str(DECISION_SCHEMA),
            "TOOL_STATUS_CANONICAL_CODEX_HOME": str(CANONICAL_HOME / ".codex"),
            "TOOL_STATUS_NOTIFICATION_DRY_RUN": "1",
            "TOOL_STATUS_TEST_ALLOW_MODEL_DEPLOY": "1",
            "TOOL_STATUS_APPROVAL_GRACE_SECONDS": "0",
        }
        completed = subprocess.run(
            ["/usr/bin/python3", str(WORKER)],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=1300,
            check=False,
        )
        history_path = state / "repair-history.jsonl"
        history = [
            json.loads(line)
            for line in history_path.read_text(encoding="utf-8").splitlines()
        ] if history_path.is_file() else []
        if completed.returncode != 0:
            raise AssertionError(
                f"worker exited {completed.returncode}: {completed.stdout}\n{history}"
            )
        namespace: dict[str, object] = {}
        exec(target.read_text(encoding="utf-8"), namespace)
        if namespace.get("ACTUAL_TOTAL") != 4 or namespace.get("EXPECTED_TOTAL") != 4:
            requests_path = state / "repair-requests.json"
            requests = json.loads(requests_path.read_text()) if requests_path.is_file() else []
            raise AssertionError(
                "Luna/max fixture was not promoted.\n"
                f"target={target.read_text(encoding='utf-8')}\n"
                f"requests={json.dumps(requests, indent=2)}\n"
                f"history={json.dumps(history, indent=2)}"
            )
        starts = [event for event in history if event.get("event") == "luna-started"]
        assert starts and starts[-1].get("model") == "gpt-5.6-luna"
        assert starts[-1].get("reasoning") == "max"
        successes = [event for event in history if event.get("event") == "repair-succeeded"]
        assert successes and successes[-1].get("outcome") == "durable_model_repair"
        assert not list(queue.glob("*.json"))

    print("live Luna/max disposable repair passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
