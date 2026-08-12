#!/usr/bin/env python3
"""Deterministic checks for repair-first incidents and escalation-only pushes."""

from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import subprocess
import threading
import tempfile
from pathlib import Path


RUNNER = Path(__file__).with_name("tool-status-background-scan.py")
SCANNER = Path(__file__).with_name("tool-status-scan.py")
NOTIFIER = Path(__file__).with_name("tool-status-notify.py")


def item(name: str, state: str, code: str, policy: str = "immediate", deadline: str | None = None) -> dict:
    return {
        "id": f"Background Job:{name}", "name": name, "category": "Background Job",
        "state": state, "headline": f"{name} plain-language cause", "detail": "full diagnostic",
        "evidence": "/tmp/evidence", "checkedAt": "2026-07-13T00:00:00+00:00", "fix": None,
        "causeCode": code, "causeParams": {}, "notificationPolicy": policy, "deadlineAt": deadline,
    }


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tool-status-test-") as temporary:
        root = Path(temporary)
        fixture = root / "fixture.json"
        scanner = root / "scanner.py"
        scanner.write_text(
            "import os,sys\nfrom pathlib import Path\n"
            "p=Path(os.environ['TOOL_STATUS_FIXTURE'])\n"
            "sys.stdout.write(p.read_text())\n",
            encoding="utf-8",
        )
        state = root / "state"
        cache = root / "cache.json"
        notification_log = root / "notifications.jsonl"
        env = {
            **os.environ,
            "TOOL_STATUS_STATE": str(state), "TOOL_STATUS_CACHE": str(cache),
            "TOOL_STATUS_SCANNER": str(scanner), "TOOL_STATUS_FIXTURE": str(fixture),
            "TOOL_STATUS_NOTIFICATION_DRY_RUN": "1",
            "TOOL_STATUS_NOTIFICATION_LOG": str(notification_log),
        }

        spec = importlib.util.spec_from_file_location("background_scan_test", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(runner)
        scanner_spec = importlib.util.spec_from_file_location("tool_status_scanner_test", SCANNER)
        scanner_module = importlib.util.module_from_spec(scanner_spec)
        assert scanner_spec.loader is not None
        scanner_spec.loader.exec_module(scanner_module)
        scanner_module.HOME = root
        production_status = root / ".local/state/personal-repo-sync/status.tsv"
        auth_status = root / ".local/state/personal-repo-sync/auth-check/status.tsv"
        production_status.parent.mkdir(parents=True)
        auth_status.parent.mkdir(parents=True)
        production_status.write_text(
            "last_attempt_at\t100\nlast_result\tfailed\nlast_detail\tGitHub authentication unavailable\n",
            encoding="utf-8",
        )
        auth_status.write_text(
            "last_attempt_at\t200\nlast_result\tverified\nlast_detail\tprivate remote verified\n",
            encoding="utf-8",
        )
        assert scanner_module.personal_repo_auth_failure_recovered()
        auth_status.write_text(
            "last_attempt_at\t50\nlast_result\tverified\n",
            encoding="utf-8",
        )
        assert not scanner_module.personal_repo_auth_failure_recovered()
        counter_one = item("Counter Tool", "fail", "counter.failed")
        counter_two = json.loads(json.dumps(counter_one))
        counter_one["causeParams"] = {"label": "com.ivo.counter", "failure_count": "1"}
        counter_two["causeParams"] = {"label": "com.ivo.counter", "failure_count": "9"}
        assert runner.item_fingerprint(counter_one) == runner.item_fingerprint(counter_two)

        def run(items: list[dict], at: str, expected: int = 0) -> None:
            fixture.write_text(json.dumps({
                "schemaVersion": 2, "generatedAt": at, "liveAuth": False, "items": items,
            }), encoding="utf-8")
            result = subprocess.run(["/usr/bin/python3", str(RUNNER)], env={**env, "TOOL_STATUS_NOW": at})
            assert result.returncode == expected, (result.returncode, at)

        def queued() -> list[dict]:
            return [json.loads(path.read_text()) for path in sorted((state / "repair-queue").glob("*.json"))]

        alpha = item("Alpha Tool", "fail", "alpha.auth", "immediate")
        run([alpha], "2026-07-13T00:00:00+00:00")
        assert queued() == [], "baseline must not enqueue historical failures"
        run([alpha], "2026-07-13T00:05:00+00:00")
        assert len(queued()) == 1 and queued()[0]["item"]["name"] == "Alpha Tool"
        assert not notification_log.exists(), "a repairable failure pushed before Terra ran"
        run([alpha], "2026-07-13T00:10:00+00:00")
        assert len(queued()) == 1, "continuous incident duplicated its repair job"
        # A consumed job with no live queue/pending file and no user stop must
        # requeue instead of stranding the incident forever.
        for path in (state / "repair-queue").glob("*.json"):
            path.unlink()
        run([alpha], "2026-07-13T00:12:00+00:00")
        assert len(queued()) == 1, "an orphaned repair flag stranded a continuous incident"
        # An explicit Dismiss/Deny remains binding for this exact fingerprint.
        for path in (state / "repair-queue").glob("*.json"):
            path.unlink()
        (state / "repair-requests.json").write_text(json.dumps([{
            "id": "repair-alpha", "incidentID": alpha["id"],
            "fingerprint": runner.item_fingerprint(alpha), "status": "denied",
        }]), encoding="utf-8")
        run([alpha], "2026-07-13T00:13:00+00:00")
        assert queued() == [], "an explicitly denied continuous incident was re-queued"

        healthy_alpha = item("Alpha Tool", "ok", "alpha.ok")
        run([healthy_alpha], "2026-07-13T00:15:00+00:00")
        incidents = json.loads((state / "incidents.json").read_text())
        assert "Background Job:Alpha Tool" in incidents["tools"]
        run([healthy_alpha], "2026-07-13T00:20:00+00:00")
        incidents = json.loads((state / "incidents.json").read_text())
        assert "Background Job:Alpha Tool" not in incidents["tools"]
        run([alpha], "2026-07-13T01:10:00+00:00")
        assert len(queued()) == 1, "new failure after recovery was not queued"
        (state / "repair-requests.json").unlink(missing_ok=True)

        beta = item("Beta Tool", "warn", "beta.offline", "consecutive")
        run([alpha, beta], "2026-07-13T01:15:00+00:00")
        assert len(queued()) == 1, "first transient failure queued"
        run([alpha, beta], "2026-07-13T01:20:00+00:00")
        assert any(job["item"]["name"] == "Beta Tool" for job in queued())

        beta_changed = item("Beta Tool", "fail", "beta.config", "immediate")
        run([alpha, beta_changed], "2026-07-13T01:25:00+00:00")
        assert any(job["item"]["causeCode"] == "beta.config" for job in queued())
        beta_deadline = item(
            "Beta Tool", "fail", "beta.deadline", "immediate", "2026-07-13T01:29:00+00:00"
        )
        run([alpha, beta_deadline], "2026-07-13T01:30:00+00:00")
        assert any(job["item"]["causeCode"] == "beta.deadline" for job in queued())
        assert not notification_log.exists(), "incident engine emitted a push instead of a repair job"

        # A self-healing condition (usage limits, transient network/timeouts) is
        # tracked but NOT escalated while it is still clearing: no repair job, no
        # push, no matter how many consecutive scans observe it within the window.
        heal = item("Self Healing Tool", "warn", "keeper.ping_retrying", "immediate")
        heal["selfHealing"] = True
        run([alpha, heal], "2026-07-13T01:33:00+00:00")
        run([alpha, heal], "2026-07-13T01:34:00+00:00")
        run([alpha, heal], "2026-07-13T01:35:00+00:00")
        assert not any(job["item"]["name"] == "Self Healing Tool" for job in queued()), \
            "a self-healing condition escalated within its grace window"
        assert not notification_log.exists(), "a self-healing condition emitted a push"
        # ...but a "transient" that NEVER clears (persists past the grace window) is
        # a real, unmasked failure and must escalate.
        run([alpha, heal], "2026-07-13T09:00:00+00:00")
        assert any(job["item"]["name"] == "Self Healing Tool" for job in queued()), \
            "a self-healing condition that never cleared failed to escalate"

        # Terra must not re-diagnose while a decision card is ALREADY waiting on Ivo.
        # This is the expensive case: a composite incident's causeCode churns between
        # scans, minting a fresh fingerprint that resets repairQueued and re-queues a
        # full model run every scan for no new information.
        requests_file = state / "repair-requests.json"
        for path in (state / "repair-queue").glob("*.json"):
            path.unlink()
        churn = item("Churn Tool", "fail", "churn.first", "immediate")
        run([churn], "2026-07-13T10:00:00+00:00")
        assert any(job["item"]["name"] == "Churn Tool" for job in queued()), "first escalation did not queue"
        # The worker has now produced an open decision card for it.
        def write_card(status: str, cause: str, updated: str) -> None:
            requests_file.write_text(json.dumps([{
                "id": "repair-churn", "incidentID": "Background Job:Churn Tool",
                "causeCode": cause, "status": status,
                "createdAt": "2026-07-13T10:00:00+00:00", "updatedAt": updated,
            }]), encoding="utf-8")
        write_card("pending", "churn.first", "2026-07-13T10:00:00+00:00")
        for path in (state / "repair-queue").glob("*.json"):
            path.unlink()
        run([churn], "2026-07-13T10:01:00+00:00")
        assert not any(job["item"]["name"] == "Churn Tool" for job in queued()), \
            "re-diagnosed while a decision card was already waiting"
        churn_two = item("Churn Tool", "fail", "churn.second", "immediate")
        run([churn_two], "2026-07-13T10:02:00+00:00")
        assert not any(job["item"]["name"] == "Churn Tool" for job in queued()), \
            "causeCode churn defeated the standing-card guard"
        # Once Ivo's card is resolved, a genuine failure escalates again.
        write_card("resolved", "churn.first", "2026-07-13T10:03:00+00:00")
        run([churn_two], "2026-07-13T10:04:00+00:00")
        assert any(job["item"]["name"] == "Churn Tool" for job in queued()), \
            "a resolved card blocked a genuine re-escalation"
        requests_file.unlink(missing_ok=True)

        # HUMAN ACTION: authentication enters the queue exactly once so the worker
        # can create a scanner-owned action card without invoking Luna.
        for path in (state / "repair-queue").glob("*.json"):
            path.unlink()
        auth_item = item("GWS live login", "fail", "auth.expired", "immediate")
        auth_item["category"] = "Auth"
        run([auth_item], "2026-07-13T11:00:00+00:00")
        run([auth_item], "2026-07-13T11:01:00+00:00")
        assert any(job["item"]["name"] == "GWS live login" for job in queued()), \
            "an Auth incident did not reach the deterministic human-action lane"
        # Same for any tool whose fix is an interactive sign-in, whatever its category.
        launch_item = item("Some Service", "fail", "service.auth_required", "immediate")
        launch_item["fix"] = {"label": "Log in", "kind": "launch", "command": ["x", "login"], "note": ""}
        run([launch_item], "2026-07-13T11:02:00+00:00")
        run([launch_item], "2026-07-13T11:03:00+00:00")
        assert any(job["item"]["name"] == "Some Service" for job in queued()), \
            "a scanner-owned sign-in action did not reach the human-action lane"
        # ...but a normal repairable failure still escalates.
        normal = item("Normal Tool", "fail", "normal.broken", "immediate")
        run([normal], "2026-07-13T11:04:00+00:00")
        assert any(job["item"]["name"] == "Normal Tool" for job in queued()), \
            "the needs-Ivo gate blocked a genuinely repairable incident"

        # INVARIANT: every Auth failure path must be one-click. The worker turns
        # queued Auth incidents into deterministic cards without model diagnosis, so one
        # that offered only copy-paste guidance would leave him stuck with nothing
        # working on it. All Auth records live in auth_records(); the sole accepted
        # exception is a missing binary (command_record), where no safe one-click
        # install exists.
        scan_src = Path(__file__).with_name("tool-status-scan.py").read_text()
        start = scan_src.index("def auth_records(")
        nxt = scan_src.find("\ndef ", start + 1)
        auth_body = scan_src[start: nxt if nxt > 0 else len(scan_src)]
        assert "fix_manual(" not in auth_body, (
            "an Auth failure path offers only manual guidance; Auth is gated from the "
            "model, so it must carry a one-click fix (fix_launch / fix_auto)"
        )

        (state / "wrapper-failure.json").write_text(json.dumps({"cause": "old delivery failure"}))
        run([healthy_alpha], "2026-07-13T01:37:00+00:00")
        cached = json.loads(cache.read_text())
        assert not any(row["id"] == "Background Job:Tool Status Dashboard Scanner" for row in cached["items"])
        assert not (state / "wrapper-failure.json").exists()

        scanner.write_text("import sys\nsys.stderr.write('fixture scanner broke')\nsys.exit(9)\n", encoding="utf-8")
        result = subprocess.run(
            ["/usr/bin/python3", str(RUNNER)], env={**env, "TOOL_STATUS_NOW": "2026-07-13T01:40:00+00:00"}
        )
        assert result.returncode == 1
        cached = json.loads(cache.read_text())
        assert any(row["id"] == "Background Job:Tool Status Dashboard Scanner" for row in cached["items"])

        # Brief contention is normal: the run waits for the peer and proceeds.
        # Restore the healthy fixture scanner first, so a non-zero exit here can
        # only mean the cycle was skipped rather than the child having failed.
        scanner.write_text(
            "import os,sys\nfrom pathlib import Path\n"
            "p=Path(os.environ['TOOL_STATUS_FIXTURE'])\n"
            "sys.stdout.write(p.read_text())\n",
            encoding="utf-8",
        )
        lock = (state / "scan.lock").open("a+")
        fcntl.lockf(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        threading.Timer(1.0, lambda: fcntl.lockf(lock.fileno(), fcntl.LOCK_UN)).start()
        result = subprocess.run(
            ["/usr/bin/python3", str(RUNNER)],
            env={**env, "TOOL_STATUS_LOCK_WAIT_SECONDS": "20"},
        )
        assert result.returncode == 0, "a run must wait out a peer, not skip the cycle"
        lock.close()

        # Sustained contention is a real fault. Exiting 0 here is what let the
        # scan stay starved for hours while the dashboard showed stale results,
        # so it must surface as an incident rather than as silence.
        lock = (state / "scan.lock").open("a+")
        fcntl.lockf(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(
            ["/usr/bin/python3", str(RUNNER)],
            env={**env, "TOOL_STATUS_LOCK_WAIT_SECONDS": "1"},
        )
        assert result.returncode == 1, "sustained lock starvation must report a failure"
        cached = json.loads(cache.read_text())
        starved = [
            row for row in cached["items"]
            if row["id"] == "Background Job:Tool Status Dashboard Scanner"
        ]
        assert starved and starved[0]["state"] == "fail", "starvation must emit a scanner failure row"
        fcntl.lockf(lock.fileno(), fcntl.LOCK_UN)
        lock.close()

        # Producers using the bridge now queue repair by default. Only the
        # worker's explicit --deliver path may create a native push.
        external_state = root / "external-state"
        external_env = {
            **os.environ, "TOOL_STATUS_STATE": str(external_state),
            "TOOL_STATUS_NO_KICKSTART": "1",
            "TOOL_STATUS_NOTIFICATION_DRY_RUN": "1",
            "TOOL_STATUS_NOTIFICATION_LOG": str(notification_log),
        }
        result = subprocess.run([
            "/usr/bin/python3", str(NOTIFIER), "External Worker", "failed once", "--group", "test.group",
        ], env=external_env)
        assert result.returncode == 0
        jobs = list((external_state / "repair-queue").glob("*.json"))
        assert len(jobs) == 1 and json.loads(jobs[0].read_text())["externalGroup"] == "test.group"
        assert not notification_log.exists()
        result = subprocess.run([
            "/usr/bin/python3", str(NOTIFIER), "--deliver", "External Worker", "Terra needs help",
            "--group", "test.group",
        ], env=external_env)
        assert result.returncode == 0
        delivered = [json.loads(line) for line in notification_log.read_text().splitlines()]
        assert delivered == [{"title": "External Worker", "body": "Terra needs help", "group": "test.group"}]

    print("repair-first notification checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
