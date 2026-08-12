#!/usr/bin/env python3
"""Contained integration checks for Luna staging, rollback gates, and escalation."""

from __future__ import annotations

import json
import fcntl
import importlib.util
import os
import stat
import subprocess
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
WORKER = HERE / "tool-status-repair-worker.py"
NOTIFIER = HERE / "tool-status-notify.py"
SCHEMA = HERE / "tool-status-repair-result.schema.json"
DECISION_SCHEMA = HERE / "tool-status-repair-decision.schema.json"


def executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def decision_payload(request: dict, decision: str, thoughts: str = "") -> dict:
    return {
        "schemaVersion": request.get("schemaVersion", 5),
        "incidentID": request.get("incidentID"),
        "generation": request.get("generation"),
        "revision": request.get("revision"),
        "authorityDigest": request.get("authorityDigest"),
        "requestID": request["id"],
        "decision": decision,
        "thoughts": thoughts,
        "createdAt": "2026-07-17T00:01:30+00:00",
    }


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tool-status-repair-test-") as temporary:
        root = Path(temporary)
        home = root / "home"
        state = root / "state"
        project = home / "Projects/UsageQueue"
        project.mkdir(parents=True)
        target = project / "config.py"
        target.write_text("VALUE = 'broken'\n", encoding="utf-8")
        contract = project / "tests/test_config.py"
        contract.parent.mkdir(parents=True)
        contract.write_text("assert EXPECTED_VALUE == 'fixed'\n", encoding="utf-8")
        (project / ".env").write_text("FIXTURE_VALUE=redacted\n", encoding="utf-8")
        (project / "data").mkdir()
        (project / "data/user.csv").write_text("private,user,data\n", encoding="utf-8")
        outside = root / "outside-private-fixture.txt"
        outside.write_text("redacted fixture\n", encoding="utf-8")
        (project / "outside-link").symlink_to(outside)
        scanner = root / "scanner.py"
        executable(scanner, """#!/usr/bin/env python3
import json, os
from pathlib import Path
fixed = "fixed" in (Path(os.environ["TOOL_STATUS_HOME"]) / "Projects/UsageQueue/config.py").read_text()
item = {"id":"Background Job:UsageQueue","name":"UsageQueue","category":"Background Job","state":"ok" if fixed else "fail","headline":"Ready" if fixed else "Configuration is broken","detail":"fixture","evidence":str(Path(os.environ["TOOL_STATUS_HOME"]) / "Projects/UsageQueue/config.py"),"checkedAt":"2026-07-17T00:00:00+00:00","fix":None,"causeCode":"usagequeue.fixture","causeParams":{},"notificationPolicy":"immediate","deadlineAt":None}
print(json.dumps({"schemaVersion":2,"generatedAt":"2026-07-17T00:00:00+00:00","liveAuth":False,"items":[item]}))
""")
        codex_log = root / "codex-argv.json"
        fake_codex = root / "codex"
        executable(fake_codex, """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
log_path=Path(os.environ["FAKE_CODEX_LOG"])
calls=json.loads(log_path.read_text()) if log_path.exists() else []
calls.append(args)
log_path.write_text(json.dumps(calls))
out=Path(args[args.index("--output-last-message")+1])
schema=Path(args[args.index("--output-schema")+1]).name
if schema == "tool-status-repair-decision.schema.json":
    contract=Path(os.environ["FAKE_CONTRACT"])
    result={"decision_impact":"preserves_decisions","decision_basis":"The existing test requires the fixed value.","confidence":"high","contract_citations":[{"path":str(contract),"line":1,"excerpt":"EXPECTED_VALUE == 'fixed'"}]}
    out.write_text(json.dumps(result))
    raise SystemExit(0)
mode=os.environ.get("FAKE_CODEX_MODE", "repair")
if mode in {"repair", "rollback"}:
    candidate=Path(args[args.index("-C")+1])
    project=candidate / "home/Projects/UsageQueue"
    assert not (project / ".env").exists()
    assert not (project / "data").exists()
    assert not (project / "outside-link").exists()
    path=candidate / "home/Projects/UsageQueue/config.py"
    path.write_text("VALUE = 'fixed'\\n" if mode == "repair" else "VALUE = 'stillbroken'\\n")
    result={"status":"repaired","summary":"Repaired the fixture configuration.","root_cause":"A stale value caused the failure.","decision_impact":"preserves_decisions","decision_basis":"The existing test requires the fixed value.","research_urls":[],"verification":["candidate syntax is valid"],"changed_paths":[str(path)],"requested_action":None,"hard_stop":None}
elif mode == "manual":
    result={"status":"needs_approval","summary":"A durable fix needs authority outside the editable scope.","root_cause":"The backend that owns this lifecycle is outside the candidate mapping.","decision_impact":"uncertain","decision_basis":"No existing contract proves the change.","research_urls":[],"verification":[],"changed_paths":[],"requested_action":{"kind":"permission","description":"Authorize adding an out-of-scope backend to the candidate edit scope.","risk":"Expands write authority to a backend that owns job execution.","command":None},"hard_stop":None}
elif mode == "reject":
    result={"status":"needs_approval","summary":"A durable fix needs a disallowed command.","root_cause":"The only fix runs an executable the worker refuses to run unattended.","decision_impact":"uncertain","decision_basis":"The command is outside the contract.","research_urls":[],"verification":[],"changed_paths":[],"requested_action":{"kind":"command","description":"Run a disallowed executable.","risk":"Uses an interpreter the worker refuses.","command":["/bin/rm","-rf","/tmp/tool-status-does-not-exist-xyz"]},"hard_stop":None}
else:
    command=["/usr/bin/touch", os.environ["FAKE_APPROVAL_MARKER"]]
    result={"status":"needs_approval","summary":"Authentication requires user authority.","root_cause":"The safe scope excludes credentials.","decision_impact":"overrides_decision","decision_basis":"Authentication remains user-owned.","research_urls":[],"verification":[],"changed_paths":[],"requested_action":{"kind":"command","description":"Create the exact one-time approval marker.","risk":"This represents a protected authentication action.","command":command},"hard_stop":None}
out.write_text(json.dumps(result))
""")
        notification_log = root / "notifications.jsonl"
        env = {
            **os.environ,
            "TOOL_STATUS_HOME": str(home), "TOOL_STATUS_STATE": str(state),
            "TOOL_STATUS_SCANNER": str(scanner), "TOOL_STATUS_CODEX": str(fake_codex),
            "TOOL_STATUS_REPAIR_SCHEMA": str(SCHEMA), "TOOL_STATUS_NOTIFIER": str(NOTIFIER),
            "TOOL_STATUS_DECISION_SCHEMA": str(DECISION_SCHEMA),
            "TOOL_STATUS_NOTIFICATION_DRY_RUN": "1",
            "TOOL_STATUS_TEST_ALLOW_MODEL_DEPLOY": "1",
            "TOOL_STATUS_NOTIFICATION_LOG": str(notification_log),
            "TOOL_STATUS_APPROVAL_GRACE_SECONDS": "0",
            "TOOL_STATUS_NOTIFY_COOLDOWN_SECONDS": "0",
            "FAKE_CODEX_LOG": str(codex_log), "FAKE_CODEX_MODE": "repair",
            "FAKE_CONTRACT": str(contract),
        }
        # Unknown/new tools default to read-only diagnosis, never staged writes.
        previous_home = os.environ.get("TOOL_STATUS_HOME")
        os.environ["TOOL_STATUS_HOME"] = str(home)
        spec = importlib.util.spec_from_file_location("repair_policy_test", WORKER)
        policy = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(policy)
        novel_roots, _ = policy.owner_scope({
            "id": "Novel:FutureTool", "name": "Future Unregistered Tool",
            "category": "Future Category", "headline": "Unexpected failure",
            "detail": "No registered path", "evidence": "none", "fix": None,
        })
        assert novel_roots == [], "a novel tool received autonomous write scope"
        market_dispatcher = home / "Projects/Market/scripts/market-refresh"
        market_dispatcher.parent.mkdir(parents=True)
        market_dispatcher.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        market_roots, _ = policy.owner_scope({
            "id": "Background Job:Market Background Refresh", "name": "Market Background Refresh",
            "category": "Background Job", "headline": "X authentication is unavailable",
            "causeCode": "market.x_auth_required", "causeParams": {"label": "com.ivo.market.refresh"},
            "detail": "credential evidence", "evidence": "Safari Cookies.binarycookies", "fix": None,
        })
        assert market_roots == [market_dispatcher], "Market auth escaped its dispatcher-only write scope"
        auth_job_unit = {
            "id": "Background Job:Market Background Refresh", "fingerprint": "auth-unit",
            "item": {
                "id": "Background Job:Market Background Refresh", "name": "Market Background Refresh",
                "category": "Background Job", "state": "fail",
                "causeCode": "market.x_auth_required", "causeParams": {"label": "com.ivo.market.refresh"},
            },
        }
        auth_recovery = policy.market_x_auth_recovery(auth_job_unit)
        assert auth_recovery is not None
        assert auth_recovery["requested_action"]["command"] == [
            "/usr/bin/open", "-b", "com.apple.Safari", "https://x.com/login",
        ], "known X auth recovery did not use the immutable Safari action"
        assert policy.market_x_auth_recovery({
            **auth_job_unit, "item": {**auth_job_unit["item"], "causeCode": "market.refresh_failed"},
        }) is None, "generic Market failure was incorrectly treated as an auth incident"
        x_health = home / "Projects/Market/state/x_scrape_status.json"
        x_health.parent.mkdir(parents=True, exist_ok=True)
        x_health.write_text(json.dumps({"status": "ok", "checked_at": policy.iso()}), encoding="utf-8")
        generic_market_job = {
            **auth_job_unit,
            "item": {**auth_job_unit["item"], "causeCode": "market.refresh_failed"},
        }
        assert policy.luna_claims_stale_market_auth(generic_market_job, {
            "summary": "Sign in to X again.", "root_cause": "Authentication expired.",
            "requested_action": {"description": "Open the Market app and sign in."},
        }), "fresh healthy X evidence did not reject stale auth guidance"
        assert not policy.luna_claims_stale_market_auth(generic_market_job, {
            "summary": "The debrief retry is delayed.", "root_cause": "Its backoff timer is still active.",
            "requested_action": None,
        }), "non-auth guidance was incorrectly rejected"
        scheduler_roots, _ = policy.owner_scope({
            "id": "Background Job:Market Background Refresh", "name": "Market Background Refresh",
            "category": "Background Job", "headline": "LaunchAgent last exited with 1",
            "causeCode": "market.scheduler_last_run_failed",
            "causeParams": {"label": "com.ivo.market.refresh"},
            "detail": str(home / "Applications/Market.app/Contents/MacOS/Market"),
            "evidence": str(home / ".local/bin/market-refresh"), "fix": None,
        })
        assert scheduler_roots == [market_dispatcher], (
            "Market scheduler failure escaped the canonical dispatcher-only write scope"
        )
        for directory in ("adapters", "pipeline", "tests", "state", "inbox", "out", "knowledge"):
            (home / "Projects/Market" / directory).mkdir(parents=True, exist_ok=True)
        curated_roots, _ = policy.owner_scope({
            "id": "Background Job:Market Background Refresh", "name": "Market Background Refresh",
            "category": "Background Job", "headline": "X renderer failed",
            "causeCode": "market.x_profile_render_empty",
            "causeParams": {"label": "com.ivo.market.refresh"},
        })
        assert market_dispatcher in curated_roots
        assert all((home / "Projects/Market" / name) in curated_roots for name in ("adapters", "pipeline", "tests"))
        assert all(
            (home / "Projects/Market" / name) not in curated_roots
            for name in ("state", "inbox", "out", "knowledge")
        )
        deploy_ok, _ = policy.autonomous_model_deploy_allowed(
            {
                "id": "Background Job:Market Background Refresh", "fingerprint": "market-scope",
                "item": {"causeCode": "market.x_profile_render_empty"},
            },
            [{"path": str(market_dispatcher)}],
        )
        assert deploy_ok, "curated non-auth Market cause was not deploy-eligible"
        deploy_ok, _ = policy.autonomous_model_deploy_allowed(
            auth_job_unit, [{"path": str(market_dispatcher)}],
        )
        assert not deploy_ok, "Market authentication became autonomously deployable"
        production_marker = home / "Projects/Market/state/production.json"
        production_marker.write_text('{"safe":true}\n', encoding="utf-8")
        corrupt_candidate = root / "corrupt-market-refresh"
        executable(corrupt_candidate, f"""#!/bin/bash
printf hacked > {str(production_marker)!r} 2>/dev/null || true
printf '{{bad json\\n' > "$MARKET_ROOT/state/candidate.json"
exit 0
""")
        corrupt_change = {
            "path": str(market_dispatcher), "kind": "modified",
            "before": {"hash": policy.file_hash(market_dispatcher), "size": market_dispatcher.stat().st_size},
            "after": {
                "hash": policy.file_hash(corrupt_candidate), "size": corrupt_candidate.stat().st_size,
                "candidate": str(corrupt_candidate),
            },
        }
        preflight_ok, preflight_note = policy.market_candidate_preflight(
            {
                "id": "Background Job:Market Background Refresh",
                "item": {"causeCode": "market.scheduler_last_run_failed"},
            },
            [corrupt_change],
            root / "market-preflight-workspace",
        )
        assert not preflight_ok, (
            f"malformed disposable Market output passed promotion: {preflight_note}"
        )
        assert production_marker.read_text(encoding="utf-8") == '{"safe":true}\n', (
            "Market preflight modified production data"
        )
        market_installed = home / ".local/bin/market-refresh"
        market_installed.parent.mkdir(parents=True)
        market_installed.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        market_job = {
            "id": "Background Job:Market Background Refresh",
            "item": {
                "id": "Background Job:Market Background Refresh",
                "name": "Market Background Refresh", "category": "Background Job",
                "state": "fail", "causeCode": "market.x_profile_render_empty",
                "causeParams": {"label": "com.ivo.market.refresh"},
                "fix": {"kind": "auto", "command": [str(market_installed), "--request-ingest"]},
            },
        }
        original_run, original_payload = policy.run, policy.current_payload
        policy.run = lambda *_args, **_kwargs: (0, "queued")
        policy.current_payload = lambda: {
            "items": [{"id": market_job["id"], "name": "Market Background Refresh", "state": "ok"}]
        }
        try:
            fixed, attempted, command_ok, _detail = policy.deterministic_fix(market_job)
            assert fixed and attempted and command_ok, "Market request-ingest recipe was not allowlisted"
            assert policy.deterministic_verification_delay(market_job) == 45 * 60
            assert policy.target_in_progress({"items": [{
                "id": market_job["id"], "name": "Market Background Refresh", "state": "warn",
                "headline": "Refresh in progress; awaiting producer health",
            }]}, market_job)
        finally:
            policy.run, policy.current_payload = original_run, original_payload

        # The known EX_CONFIG incident has a worker-owned signed rebuild path.
        # The model cannot edit or substitute the build script, and the rebuild
        # runs in the no-network sandbox before strict signature verification.
        signature_app = root / "Applications/Market.app"
        signature_app.mkdir(parents=True)
        signature_build = root / "Market/app/packaging/build-app.sh"
        signature_build.parent.mkdir(parents=True)
        executable(signature_build, "#!/bin/bash\nexit 0\n")
        signature_agent = root / "Library/LaunchAgents/com.ivo.market.refresh.plist"
        signature_agent.parent.mkdir(parents=True)
        signature_agent.write_text("fixture\n", encoding="utf-8")
        original_market_app = policy.MARKET_APP
        original_market_build = policy.MARKET_APP_BUILD
        original_market_agent = policy.MARKET_LAUNCH_AGENT
        original_run = policy.run
        signature_commands = []
        signature_checks = 0

        def fake_signature_run(command, **_kwargs):
            nonlocal signature_checks
            signature_commands.append(command)
            if command[:2] == ["/usr/bin/codesign", "--verify"]:
                signature_checks += 1
                return (1, "invalid signature") if signature_checks == 1 else (0, "")
            return 0, "ok"

        policy.MARKET_APP = signature_app
        policy.MARKET_APP_BUILD = signature_build
        policy.MARKET_LAUNCH_AGENT = signature_agent
        policy.run = fake_signature_run
        try:
            fixed, attempted, _detail = policy.market_signature_repair({
                "id": "Background Job:Market Background Refresh",
                "item": {
                    "causeCode": "market.scheduler_last_run_failed",
                    "detail": "Producer exited EX_CONFIG because its strict signature is invalid.",
                },
            })
            assert fixed and attempted
            assert [
                "/usr/bin/sandbox-exec", "-p", policy.NO_NETWORK_PROFILE,
                str(signature_build),
            ] in signature_commands
            assert signature_checks == 2
            assert [
                "/bin/launchctl", "bootstrap", f"gui/{os.getuid()}",
                str(signature_agent),
            ] in signature_commands
            assert [
                "/bin/launchctl", "kickstart",
                f"gui/{os.getuid()}/com.ivo.market.refresh",
            ] in signature_commands
            command_count = len(signature_commands)
            fixed, attempted, _detail = policy.market_signature_repair({
                "id": "Background Job:Market Background Refresh",
                "item": {
                    "causeCode": "market.x_scrape_failed",
                    "detail": "Producer exited EX_CONFIG because its signature is invalid.",
                },
            })
            assert not fixed and not attempted
            assert len(signature_commands) == command_count, (
                "near-match Market cause invoked the signed rebuild"
            )
            build_count = signature_commands.count([
                "/usr/bin/sandbox-exec", "-p", policy.NO_NETWORK_PROFILE,
                str(signature_build),
            ])
            fixed, attempted, _detail = policy.market_signature_repair({
                "id": "Background Job:Market Background Refresh",
                "item": {
                    "causeCode": "market.scheduler_last_run_failed",
                    "detail": "Producer exited EX_CONFIG but the installed signature is valid.",
                },
            })
            assert fixed and attempted, (
                "valid Market signature did not refresh launchd's stale signed identity"
            )
            assert signature_commands.count([
                "/usr/bin/sandbox-exec", "-p", policy.NO_NETWORK_PROFILE,
                str(signature_build),
            ]) == build_count, "valid Market signature unnecessarily invoked the rebuild"
        finally:
            policy.MARKET_APP = original_market_app
            policy.MARKET_APP_BUILD = original_market_build
            policy.MARKET_LAUNCH_AGENT = original_market_agent
            policy.run = original_run

        # Pending non-auth incidents from the old policy are requeued exactly
        # once, while their existing card moves to a visible reconsidering state.
        policy.PENDING.mkdir(parents=True, exist_ok=True)
        policy.QUEUE.mkdir(parents=True, exist_ok=True)
        legacy_job = {
            "schemaVersion": 1,
            "id": "Background Job:UsageQueue",
            "fingerprint": "legacy-policy-fixture",
            "createdAt": "2026-07-17T00:00:00+00:00",
            "repairPolicyVersion": 1,
            "attempts": 4,
            "deterministicAttemptedAt": "2026-07-17T00:01:00+00:00",
            "marketSignatureRepairAttemptedAt": "2026-07-17T00:02:00+00:00",
            "item": {
                "id": "Background Job:UsageQueue",
                "name": "UsageQueue",
                "category": "Background Job",
                "state": "fail",
                "causeCode": "usagequeue.fixture",
            },
        }
        legacy_key = policy.repair_key(legacy_job)
        (policy.PENDING / f"{legacy_key}.json").write_text(
            json.dumps(legacy_job), encoding="utf-8",
        )
        policy.save_requests([{
            "id": f"repair-{legacy_key}",
            "incidentID": legacy_job["id"],
            "pendingKey": legacy_key,
            "status": "pending",
        }])
        policy.reconsider_legacy_pending()
        policy.reconsider_legacy_pending()
        queued_legacy = list(policy.QUEUE.glob("*.json"))
        assert len(queued_legacy) == 1
        reconsidered_job = json.loads(queued_legacy[0].read_text(encoding="utf-8"))
        assert reconsidered_job["repairPolicyVersion"] == policy.REPAIR_POLICY_VERSION
        assert reconsidered_job["legacyPolicyReconsideration"] is True
        assert reconsidered_job["attempts"] == 0
        assert "deterministicAttemptedAt" not in reconsidered_job
        assert "marketSignatureRepairAttemptedAt" not in reconsidered_job
        reconsidered_request = policy.load_requests()[0]
        assert reconsidered_request["status"] == "reconsidering"
        assert reconsidered_request["reasoning"] == "max"
        legacy_events = [
            json.loads(line)
            for line in policy.HISTORY.read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("event") == "pending-requeued-for-policy"
        ]
        assert len(legacy_events) == 1, "legacy pending incident was requeued more than once"
        for cleanup in queued_legacy:
            cleanup.unlink()
        policy.REQUESTS.unlink(missing_ok=True)
        policy.HISTORY.unlink(missing_ok=True)
        (policy.PENDING / f"{legacy_key}.json").unlink(missing_ok=True)

        # A staged candidate cannot overwrite a file that changed after the
        # snapshot, and a rollback cannot overwrite a later human edit.
        conflict_target = project / "concurrency.py"
        conflict_candidate = root / "concurrency-candidate.py"
        conflict_target.write_text("VALUE = 'snapshot'\n", encoding="utf-8")
        conflict_candidate.write_text("VALUE = 'automatic'\n", encoding="utf-8")
        conflict_change = {
            "path": str(conflict_target), "kind": "modified",
            "before": {"hash": policy.file_hash(conflict_target), "size": conflict_target.stat().st_size},
            "after": {
                "hash": policy.file_hash(conflict_candidate), "size": conflict_candidate.stat().st_size,
                "candidate": str(conflict_candidate),
            },
        }
        conflict_job = {"id": "Concurrency:Apply", "fingerprint": "fixture-apply-conflict"}
        conflict_target.write_text("VALUE = 'human-before-apply'\n", encoding="utf-8")
        try:
            policy.apply_changes([conflict_change], conflict_job)
            raise AssertionError("stale candidate overwrote a concurrent edit")
        except policy.ConcurrentModificationError:
            pass
        assert conflict_target.read_text() == "VALUE = 'human-before-apply'\n"

        conflict_target.write_text("VALUE = 'snapshot'\n", encoding="utf-8")
        rollback_path = policy.apply_changes([conflict_change], conflict_job)
        assert conflict_target.read_text() == "VALUE = 'automatic'\n"
        conflict_target.write_text("VALUE = 'human-before-rollback'\n", encoding="utf-8")
        restored, conflicts = policy.rollback_changes(rollback_path)
        assert restored == [] and conflicts == [str(conflict_target)]
        assert conflict_target.read_text() == "VALUE = 'human-before-rollback'\n"

        second_target = project / "concurrency-second.py"
        second_candidate = root / "concurrency-second-candidate.py"
        conflict_target.write_text("VALUE = 'snapshot'\n", encoding="utf-8")
        second_target.write_text("VALUE = 'snapshot-two'\n", encoding="utf-8")
        second_candidate.write_text("VALUE = 'automatic-two'\n", encoding="utf-8")
        first_multi = {
            **conflict_change,
            "before": {"hash": policy.file_hash(conflict_target), "size": conflict_target.stat().st_size},
        }
        second_multi = {
            "path": str(second_target), "kind": "modified",
            "before": {"hash": policy.file_hash(second_target), "size": second_target.stat().st_size},
            "after": {
                "hash": policy.file_hash(second_candidate), "size": second_candidate.stat().st_size,
                "candidate": str(second_candidate),
            },
        }
        multi_job = {"id": "Concurrency:PartialRollback", "fingerprint": "fixture-partial"}
        multi_rollback = policy.apply_changes([first_multi, second_multi], multi_job)
        conflict_target.write_text("VALUE = 'human-partial'\n", encoding="utf-8")
        restored, conflicts = policy.rollback_changes(multi_rollback)
        assert restored == [str(second_target)] and conflicts == [str(conflict_target)]
        assert conflict_target.read_text() == "VALUE = 'human-partial'\n"
        assert second_target.read_text() == "VALUE = 'snapshot-two'\n"

        dispatcher_candidate = root / "market-refresh-candidate"
        dispatcher_candidate.write_text("#!/bin/bash\necho automatic\n", encoding="utf-8")
        dispatcher_change = {
            "path": str(market_dispatcher), "kind": "modified",
            "before": {"hash": policy.file_hash(market_dispatcher), "size": market_dispatcher.stat().st_size},
            "after": {
                "hash": policy.file_hash(dispatcher_candidate), "size": dispatcher_candidate.stat().st_size,
                "candidate": str(dispatcher_candidate),
            },
        }
        projection_job = {"id": "Market:Projection", "fingerprint": "fixture-projection-conflict"}
        projection_rollback = policy.apply_changes([dispatcher_change], projection_job)
        policy.atomic_copy(market_dispatcher, market_installed)
        market_dispatcher.write_text("#!/bin/bash\necho human\n", encoding="utf-8")
        detail = policy.rollback_and_restore(projection_rollback, [dispatcher_change], {})
        assert "reconciled" in detail
        assert market_installed.read_text() == market_dispatcher.read_text(), (
            "rollback conflict left the failed Market projection installed"
        )
        if previous_home is None:
            del os.environ["TOOL_STATUS_HOME"]
        else:
            os.environ["TOOL_STATUS_HOME"] = previous_home

        # Market's quick request command defers health verification for the
        # scraper runtime, then closes silently when the producer turns healthy.
        market_state = root / "market-state"
        market_queue = market_state / "repair-queue"
        market_queue.mkdir(parents=True)
        requested_marker = root / "market-requested"
        healthy_marker = root / "market-healthy"
        executable(market_installed, f"#!/bin/bash\ntouch '{requested_marker}'\n")
        market_scanner = root / "market-scanner.py"
        executable(market_scanner, f'''#!/usr/bin/env python3
import json
from pathlib import Path
healthy=Path({str(healthy_marker)!r}).exists()
item={{"id":"Background Job:Market Background Refresh","name":"Market Background Refresh","category":"Background Job","state":"ok" if healthy else "fail","headline":"Ready" if healthy else "X rendered no posts","detail":"fixture","evidence":"fixture","checkedAt":"2026-07-17T00:00:00+00:00","fix":{{"kind":"auto","command":[{str(market_installed)!r},"--request-ingest"]}},"causeCode":"market.x_profile_render_empty","causeParams":{{"label":"com.ivo.market.refresh"}},"notificationPolicy":"consecutive","deadlineAt":None}}
print(json.dumps({{"schemaVersion":2,"generatedAt":"2026-07-17T00:00:00+00:00","liveAuth":False,"items":[item]}}))
''')
        deferred_job = {
            "schemaVersion": 1, "id": "Background Job:Market Background Refresh",
            "fingerprint": "fixture-market-deferred", "createdAt": "2026-07-17T00:00:00+00:00",
            "attempts": 0, "nextAttemptAt": "2026-07-17T00:00:00+00:00",
            "item": market_job["item"],
        }
        deferred_path = market_queue / "market.json"
        deferred_path.write_text(json.dumps(deferred_job), encoding="utf-8")
        market_env = {
            **env, "TOOL_STATUS_STATE": str(market_state),
            "TOOL_STATUS_SCANNER": str(market_scanner),
        }
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=market_env, check=True)
        assert requested_marker.exists(), "Market request-ingest command did not run"
        deferred = json.loads(deferred_path.read_text())
        assert deferred.get("deterministicAttemptedAt") and deferred.get("nextAttemptAt")
        healthy_marker.touch()
        deferred["nextAttemptAt"] = "2026-07-17T00:00:00+00:00"
        deferred_path.write_text(json.dumps(deferred), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=market_env, check=True)
        assert not deferred_path.exists(), "healthy Market producer did not close deferred repair"
        assert not (market_state / "notification-outbox.json").exists(), "Market recovery emitted a push"
        market_history = [
            json.loads(line) for line in (market_state / "repair-history.jsonl").read_text().splitlines()
        ]
        market_success = [event for event in market_history if event["event"] == "repair-succeeded"]
        assert market_success and market_success[-1]["outcome"] == "recovered_before_repair"

        # A second launchd fire while another process owns the worker lock exits
        # cleanly and cannot create work, history, or notifications.
        state.mkdir(parents=True, exist_ok=True)
        lock_path = state / "repair.lock"
        lock = lock_path.open("a+")
        fcntl.lockf(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        overlap = subprocess.run(["/usr/bin/python3", str(WORKER)], env=env)
        assert overlap.returncode == 0
        assert not (state / "repair-history.jsonl").exists()
        fcntl.lockf(lock.fileno(), fcntl.LOCK_UN)
        lock.close()
        queue = state / "repair-queue"
        queue.mkdir(parents=True, exist_ok=True)
        job = {
            "schemaVersion": 1, "id": "Background Job:UsageQueue", "fingerprint": "fixture-safe",
            "createdAt": "2026-07-17T00:00:00+00:00", "attempts": 0,
            "nextAttemptAt": "2026-07-17T00:00:00+00:00",
            "item": {"id":"Background Job:UsageQueue","name":"UsageQueue","category":"Background Job","state":"fail","headline":"Configuration is broken","detail":"fixture","evidence":str(target),"checkedAt":"2026-07-17T00:00:00+00:00","fix":None,"causeCode":"usagequeue.fixture","causeParams":{},"notificationPolicy":"immediate","deadlineAt":None},
        }
        (queue / "safe.json").write_text(json.dumps(job), encoding="utf-8")
        result = subprocess.run(["/usr/bin/python3", str(WORKER)], env=env)
        assert result.returncode == 0
        if target.read_text() != "VALUE = 'fixed'\n":
            evidence = (state / "repair-history.jsonl").read_text() if (state / "repair-history.jsonl").exists() else "no history"
            raise AssertionError(f"staged repair was not applied:\n{evidence}")
        assert not list(queue.glob("*.json")), "successful repair remained queued"
        assert not any((state / "repair-workspaces").iterdir()), "successful candidate was retained"
        assert not notification_log.exists(), "successful autonomous repair emitted a push"
        history = [json.loads(line) for line in (state / "repair-history.jsonl").read_text().splitlines()]
        model_success = [event for event in history if event["event"] == "repair-succeeded"]
        assert model_success and model_success[-1]["outcome"] == "durable_model_repair"
        calls = json.loads(codex_log.read_text())
        repair_argv = next(argv for argv in calls if argv[argv.index("--sandbox") + 1] == "workspace-write")
        audit_argv = next(argv for argv in calls if argv[argv.index("--sandbox") + 1] == "read-only")
        assert repair_argv[repair_argv.index("--model") + 1] == "gpt-5.6-luna"
        assert 'model_reasoning_effort="max"' in repair_argv
        assert 'approval_policy="never"' in repair_argv
        assert "sandbox_workspace_write.network_access=false" in repair_argv
        assert "--ignore-user-config" in repair_argv and "--ignore-rules" in repair_argv
        assert "sandbox_workspace_write.network_access=false" in audit_argv
        repair_codex_home = state / "codex-home"
        assert (repair_codex_home / "AGENTS.md").is_symlink()
        assert {
            path.name for path in (repair_codex_home / "skills").iterdir()
        } == {"vibe-coding", "macos-background-jobs"}

        # A syntactically valid change that does not restore health is rolled
        # back and retried silently. Model inability is not a human decision.
        target.write_text("VALUE = 'broken'\n", encoding="utf-8")
        rollback_state = root / "rollback-state"
        rollback_queue = rollback_state / "repair-queue"
        rollback_queue.mkdir(parents=True)
        rollback_job = {**job, "fingerprint": "fixture-rollback"}
        (rollback_queue / "rollback.json").write_text(json.dumps(rollback_job), encoding="utf-8")
        rollback_log = root / "rollback-notifications.jsonl"
        rollback_env = {
            **env, "TOOL_STATUS_STATE": str(rollback_state), "FAKE_CODEX_MODE": "rollback",
            "TOOL_STATUS_NOTIFICATION_LOG": str(rollback_log),
        }
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=rollback_env, check=True)
        assert target.read_text() == "VALUE = 'broken'\n", "failed repair was not rolled back"
        assert not (rollback_state / "repair-requests.json").exists(), \
            "a fully rolled-back unsuccessful repair created a human decision"
        assert not rollback_log.exists(), "a fully rolled-back unsuccessful repair pushed"
        retry_jobs = list(rollback_queue.glob("*.json"))
        assert len(retry_jobs) == 1 and json.loads(retry_jobs[0].read_text())["attempts"] == 1, \
            "the unsuccessful contained repair was not retained for silent retry"

        # Protected failures still get full Terra diagnosis, but no write scope.
        protected_state = root / "protected-state"
        protected_queue = protected_state / "repair-queue"
        protected_queue.mkdir(parents=True)
        protected_scanner = root / "protected-scanner.py"
        executable(protected_scanner, """#!/usr/bin/env python3
import json, os
from pathlib import Path
healthy=Path(os.environ["FAKE_APPROVAL_MARKER"]).exists()
item={"id":"Auth:Example","name":"Example Authentication","category":"Auth","state":"ok" if healthy else "fail","headline":"Ready" if healthy else "Login expired","detail":"fixture","evidence":"credential metadata only","checkedAt":"2026-07-17T00:00:00+00:00","fix":None,"needsIvo":not healthy,"causeCode":"auth.expired","causeParams":{},"notificationPolicy":"immediate","deadlineAt":None}
print(json.dumps({"schemaVersion":2,"generatedAt":"2026-07-17T00:00:00+00:00","liveAuth":False,"items":[item]}))
""")
        protected_job = {
            "schemaVersion": 1, "id": "Auth:Example", "fingerprint": "fixture-protected",
            "createdAt": "2026-07-17T00:00:00+00:00", "attempts": 0,
            "nextAttemptAt": "2026-07-17T00:00:00+00:00",
            "item": {"id":"Auth:Example","name":"Example Authentication","category":"Auth","state":"fail","headline":"Login expired","detail":"fixture","evidence":"credential metadata only","checkedAt":"2026-07-17T00:00:00+00:00","fix":None,"needsIvo":True,"causeCode":"auth.expired","causeParams":{},"notificationPolicy":"immediate","deadlineAt":None},
        }
        (protected_queue / "protected.json").write_text(json.dumps(protected_job), encoding="utf-8")
        protected_env = {
            **env, "TOOL_STATUS_STATE": str(protected_state),
            "TOOL_STATUS_SCANNER": str(protected_scanner), "FAKE_CODEX_MODE": "approval",
            "FAKE_APPROVAL_MARKER": str(root / "deny-marker"),
            "TOOL_STATUS_NOTIFICATION_LOG": str(root / "protected-notifications.jsonl"),
        }
        result = subprocess.run(["/usr/bin/python3", str(WORKER)], env=protected_env)
        assert result.returncode == 0
        requests = json.loads((protected_state / "repair-requests.json").read_text())
        assert len(requests) == 1 and requests[0]["status"] == "pending"
        assert requests[0]["requestedAction"] is None
        assert requests[0]["authorityStatus"] == "human-only" and len(requests[0]["authorityDigest"]) == 64
        protected_log = Path(protected_env["TOOL_STATUS_NOTIFICATION_LOG"])
        pushes = [json.loads(line) for line in protected_log.read_text().splitlines()]
        # Authentication push copy names the concrete user action and never asks
        # for broad repair authority or a separate full-agent session.
        assert len(pushes) == 1, "same incident pushed the wrong number of times"
        assert "sign in" in pushes[0]["body"].lower() and "agent session" not in pushes[0]["body"].lower(), \
            "push body did not name the concrete authentication action"
        original_request_id = requests[0]["id"]
        # A changed scan fingerprint for the same producer incident updates the
        # existing card and pending job instead of creating another approval.
        repeated_job = {
            **protected_job, "fingerprint": "fixture-protected-count-2",
            "createdAt": "2026-07-17T00:01:00+00:00",
        }
        (protected_queue / "repeated.json").write_text(json.dumps(repeated_job), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=protected_env, check=True)
        requests = json.loads((protected_state / "repair-requests.json").read_text())
        assert len(requests) == 1, "one incident produced duplicate approval cards"
        assert requests[0]["id"] != original_request_id, "new incident generation reused approval authority"
        assert len(list((protected_state / "repair-pending").glob("*.json"))) == 1
        assert len(protected_log.read_text().splitlines()) == 2, "replacement incident generation should notify once"
        decision_dir = protected_state / "repair-decisions"
        decision_dir.mkdir(parents=True, exist_ok=True)
        (decision_dir / "stale-approve.json").write_text(json.dumps({
            "schemaVersion": 4, "generation": requests[0]["generation"], "revision": requests[0]["revision"],
            "planDigest": requests[0]["planDigest"], "requestID": original_request_id,
            "decision": "approve", "thoughts": "", "createdAt": "2026-07-17T00:01:30+00:00",
        }), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=protected_env, check=True)
        assert not Path(protected_env["FAKE_APPROVAL_MARKER"]).exists(), "stale approval executed a newer action"
        assert json.loads((protected_state / "repair-requests.json").read_text())[0]["status"] == "pending"
        (decision_dir / "deny.json").write_text(json.dumps(decision_payload(
            requests[0], "deny", "Do not touch this account."
        )), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=protected_env, check=True)
        requests = json.loads((protected_state / "repair-requests.json").read_text())
        assert requests[0]["status"] == "denied"
        assert not list((protected_state / "repair-pending").glob("*.json"))
        assert len(protected_log.read_text().splitlines()) == 2, "denial emitted an unexpected extra push"

        # Approval executes the displayed argv once without a shell, then the
        # health rescan consumes the job. Replaying the decision is a no-op.
        approval_state = root / "approval-state"
        approval_queue = approval_state / "repair-queue"
        approval_queue.mkdir(parents=True)
        approval_marker = root / "approved;literal"
        approval_log = root / "approval-notifications.jsonl"
        approval_scanner = root / "approval-scanner.py"
        executable(approval_scanner, """#!/usr/bin/env python3
import json, os
from pathlib import Path
healthy=Path(os.environ["FAKE_APPROVAL_MARKER"]).exists()
item={"id":"Auth:Example","name":"Example Scheduled Repair","category":"Scheduled Work","state":"ok" if healthy else "fail","headline":"Ready" if healthy else "Job failed","detail":"fixture","evidence":"local fixture","checkedAt":"2026-07-17T00:00:00+00:00","fix":None,"needsIvo":False,"causeCode":"job.failed","causeParams":{},"notificationPolicy":"immediate","deadlineAt":None}
print(json.dumps({"schemaVersion":2,"generatedAt":"2026-07-17T00:00:00+00:00","liveAuth":False,"items":[item]}))
""")
        approval_env = {
            **env, "TOOL_STATUS_STATE": str(approval_state),
            "TOOL_STATUS_SCANNER": str(approval_scanner), "FAKE_CODEX_MODE": "approval",
            "FAKE_APPROVAL_MARKER": str(approval_marker),
            "TOOL_STATUS_NOTIFICATION_LOG": str(approval_log),
        }
        approval_item = {
            **protected_job["item"],
            "category": "Scheduled Work",
            "causeCode": "job.failed",
            "needsIvo": False,
        }
        approval_job = {
            **protected_job,
            "fingerprint": "fixture-approved",
            "item": approval_item,
        }
        (approval_queue / "approval.json").write_text(json.dumps(approval_job), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=approval_env, check=True)
        assert not (approval_state / "repair-requests.json").exists(), \
            "ordinary model inability created a broad approval request"
        assert not approval_log.exists(), "ordinary model inability produced a push"
        assert not approval_marker.exists(), "non-auth approval executed a staged command"
        queued_internal = list(approval_queue.glob("*.json"))
        assert len(queued_internal) == 1
        queued_job = json.loads(queued_internal[0].read_text())
        assert queued_job["lunaExhausted"] is True, "unchanged Luna evidence was not exhausted"
        assert "internalAgentTier" not in queued_job
        queued_job["nextAttemptAt"] = "2026-07-17T00:00:00+00:00"
        queued_internal[0].write_text(json.dumps(queued_job), encoding="utf-8")
        before_calls = len(json.loads(codex_log.read_text()))
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=approval_env, check=True)
        after_calls = json.loads(codex_log.read_text())
        assert len(after_calls) == before_calls, "unchanged evidence triggered another model call"
        assert not (approval_state / "repair-requests.json").exists()
        assert not approval_log.exists()
        approval_history = [
            json.loads(line) for line in (approval_state / "repair-history.jsonl").read_text().splitlines()
        ]
        assert any(event["event"] == "luna-call-suppressed-unchanged-evidence" for event in approval_history)

        # Recovery while a card is pending resolves it without a click. A later
        # incident generation may alert once again.
        recovery_state = root / "recovery-state"
        recovery_queue = recovery_state / "repair-queue"
        recovery_queue.mkdir(parents=True)
        recovery_marker = root / "recovery-marker"
        recovery_log = root / "recovery-notifications.jsonl"
        recovery_env = {
            **env, "TOOL_STATUS_STATE": str(recovery_state),
            "TOOL_STATUS_SCANNER": str(protected_scanner), "FAKE_CODEX_MODE": "approval",
            "FAKE_APPROVAL_MARKER": str(recovery_marker),
            "TOOL_STATUS_NOTIFICATION_LOG": str(recovery_log),
        }
        (recovery_queue / "first.json").write_text(json.dumps(protected_job), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=recovery_env, check=True)
        first_recovery_request = json.loads((recovery_state / "repair-requests.json").read_text())[0]
        recovery_marker.touch()
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=recovery_env, check=True)
        assert json.loads((recovery_state / "repair-requests.json").read_text())[0]["status"] == "resolved"
        assert not list((recovery_state / "repair-pending").glob("*.json"))
        recovery_marker.unlink()
        recurrence = {**protected_job, "createdAt": "2026-07-17T01:00:00+00:00"}
        (recovery_queue / "recurrence.json").write_text(json.dumps(recurrence), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=recovery_env, check=True)
        recurring_request = json.loads((recovery_state / "repair-requests.json").read_text())[0]
        assert recurring_request["status"] == "pending"
        assert recurring_request["id"] == first_recovery_request["id"], "same issue generation changed authority ID"
        assert recurring_request["authorityDigest"] == first_recovery_request["authorityDigest"]
        assert len(recovery_log.read_text().splitlines()) == 2

        # Known Market X authentication never goes to Terra. Approval opens only
        # the fixed Safari URL, then remains visible until fresh health confirms it.
        auth_state = root / "auth-state"
        auth_queue = auth_state / "repair-queue"
        auth_queue.mkdir(parents=True)
        auth_scanner = root / "auth-scanner.py"
        auth_item = {
            "id": "Background Job:Market Background Refresh", "name": "Market Background Refresh",
            "category": "Background Job", "state": "fail", "headline": "X sign-in required",
            "detail": "structured fixture", "evidence": "fixture", "fix": None,
            "causeCode": "market.x_auth_required", "causeParams": {"label": "com.ivo.market.refresh"},
            "notificationPolicy": "immediate", "deadlineAt": None,
            "checkedAt": "2026-07-17T00:00:00+00:00",
        }
        def write_auth_scan(item):
            executable(auth_scanner, "#!/usr/bin/env python3\nimport json\nprint(json.dumps(" + repr({
                "schemaVersion": 2, "generatedAt": "2026-07-17T00:00:00+00:00",
                "liveAuth": False, "items": [item],
            }) + "))\n")
        write_auth_scan(auth_item)
        auth_env = {
            **env, "TOOL_STATUS_STATE": str(auth_state), "TOOL_STATUS_SCANNER": str(auth_scanner),
            "FAKE_CODEX_MODE": "repair", "TOOL_STATUS_NOTIFICATION_LOG": str(root / "auth-notify.jsonl"),
            "TOOL_STATUS_AUTH_WAIT_SECONDS": "300",
        }
        auth_job = {
            "schemaVersion": 1, "id": auth_item["id"], "fingerprint": "fixture-auth",
            "createdAt": "2026-07-17T00:00:00+00:00", "attempts": 0, "item": auth_item,
        }
        codex_log.unlink(missing_ok=True)
        (auth_queue / "auth.json").write_text(json.dumps(auth_job), encoding="utf-8")
        concurrent_workers = [
            subprocess.Popen(["/usr/bin/python3", str(WORKER)], env=auth_env)
            for _ in range(2)
        ]
        assert all(worker.wait() == 0 for worker in concurrent_workers)
        assert not codex_log.exists(), "known X authentication recovery invoked Terra"
        auth_request = json.loads((auth_state / "repair-requests.json").read_text())[0]
        assert auth_request["requestedAction"]["command"] == [
            "/usr/bin/open", "-b", "com.apple.Safari", "https://x.com/login",
        ]
        assert auth_request["actionable"] is True
        auth_decisions = auth_state / "repair-decisions"
        auth_decisions.mkdir(parents=True, exist_ok=True)
        (auth_decisions / "approve.json").write_text(json.dumps(
            decision_payload(auth_request, "approve")
        ), encoding="utf-8")
        (auth_decisions / "approve-duplicate.json").write_text(json.dumps(
            decision_payload(auth_request, "approve")
        ), encoding="utf-8")
        concurrent_approvals = [
            subprocess.Popen(["/usr/bin/python3", str(WORKER)], env=auth_env)
            for _ in range(2)
        ]
        assert all(worker.wait() == 0 for worker in concurrent_approvals)
        waiting_request = json.loads((auth_state / "repair-requests.json").read_text())[0]
        assert waiting_request["status"] == "awaiting_user_auth"
        assert list((auth_state / "repair-pending").glob("*.json")), "auth wait lost its verification state"
        assert not list(auth_queue.glob("*.json")), "auth approval incorrectly requeued Terra"
        auth_history = [json.loads(line) for line in (auth_state / "repair-history.jsonl").read_text().splitlines()]
        assert sum(event["event"] == "market-x-auth-opened" for event in auth_history) == 1, \
            "duplicate approvals executed the browser action more than once"
        # An older OK snapshot cannot resolve a login approved later.
        write_auth_scan({**auth_item, "state": "ok", "headline": "Healthy", "causeCode": None})
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=auth_env, check=True)
        assert json.loads((auth_state / "repair-requests.json").read_text())[0]["status"] == \
            "awaiting_user_auth", "stale health resolved a newer authentication wait"
        write_auth_scan({
            **auth_item, "state": "ok", "headline": "Healthy", "causeCode": None,
            "checkedAt": policy.iso(),
        })
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=auth_env, check=True)
        assert json.loads((auth_state / "repair-requests.json").read_text())[0]["status"] == "resolved"
        assert not list((auth_state / "repair-pending").glob("*.json"))

        # A failed Safari launch remains pending; it never claims to be waiting
        # for a login that the app did not actually open.
        failed_auth_state = root / "failed-auth-state"
        failed_auth_queue = failed_auth_state / "repair-queue"
        failed_auth_queue.mkdir(parents=True)
        failed_auth_env = {
            **auth_env, "TOOL_STATUS_STATE": str(failed_auth_state),
            "TOOL_STATUS_FIXED_ACTION_RC": "7",
        }
        (failed_auth_queue / "auth.json").write_text(json.dumps(auth_job), encoding="utf-8")
        write_auth_scan(auth_item)
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=failed_auth_env, check=True)
        failed_request = json.loads((failed_auth_state / "repair-requests.json").read_text())[0]
        failed_decisions = failed_auth_state / "repair-decisions"
        failed_decisions.mkdir(parents=True, exist_ok=True)
        (failed_decisions / "approve.json").write_text(json.dumps(
            decision_payload(failed_request, "approve")
        ), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=failed_auth_env, check=True)
        assert json.loads((failed_auth_state / "repair-requests.json").read_text())[0]["status"] == "pending"
        assert any(
            json.loads(line)["event"] == "market-x-auth-open-failed"
            for line in (failed_auth_state / "repair-history.jsonl").read_text().splitlines()
        )
        tampered = json.loads((failed_auth_state / "repair-requests.json").read_text())
        tampered[0]["requestedAction"]["command"] = [
            "/usr/bin/open", "-b", "com.google.Chrome", "https://example.invalid/login",
        ]
        (failed_auth_state / "repair-requests.json").write_text(json.dumps(tampered), encoding="utf-8")
        (failed_decisions / "tampered.json").write_text(json.dumps(
            decision_payload(tampered[0], "approve")
        ), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env={
            **failed_auth_env, "TOOL_STATUS_FIXED_ACTION_RC": "0",
        }, check=True)
        assert json.loads((failed_auth_state / "repair-requests.json").read_text())[0]["status"] == "pending"
        assert any(
            json.loads(line)["event"] == "decision-rejected-stale"
            and "auth-exact" in json.loads(line).get("reason", "")
            for line in (failed_auth_state / "repair-history.jsonl").read_text().splitlines()
        ), "altered browser action was not rejected by the auth-exact CAS"

        # Expiry reopens the same durable request instead of creating a second
        # card or losing the health-verification job.
        expiry_state = root / "expiry-auth-state"
        expiry_queue = expiry_state / "repair-queue"
        expiry_queue.mkdir(parents=True)
        expiry_env = {**auth_env, "TOOL_STATUS_STATE": str(expiry_state)}
        (expiry_queue / "auth.json").write_text(json.dumps(auth_job), encoding="utf-8")
        write_auth_scan(auth_item)
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=expiry_env, check=True)
        expiry_request = json.loads((expiry_state / "repair-requests.json").read_text())[0]
        expiry_decisions = expiry_state / "repair-decisions"
        expiry_decisions.mkdir(parents=True, exist_ok=True)
        (expiry_decisions / "approve.json").write_text(json.dumps(
            decision_payload(expiry_request, "approve")
        ), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=expiry_env, check=True)
        expiry_pending_path = next((expiry_state / "repair-pending").glob("*.json"))
        expiry_job = json.loads(expiry_pending_path.read_text())
        expiry_job["authWaitExpiresAt"] = "2000-01-01T00:00:00+00:00"
        expiry_pending_path.write_text(json.dumps(expiry_job), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=expiry_env, check=True)
        expired_request = json.loads((expiry_state / "repair-requests.json").read_text())[0]
        assert expired_request["id"] != expiry_request["id"] and expired_request["status"] == "pending"
        assert "still cannot confirm" in expired_request["summary"]
        assert expiry_pending_path.exists(), "expiry discarded the verification job"
        (expiry_decisions / "replay-old-approval.json").write_text(json.dumps(
            decision_payload(expiry_request, "approve")
        ), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=expiry_env, check=True)
        expiry_history = [
            json.loads(line) for line in (expiry_state / "repair-history.jsonl").read_text().splitlines()
        ]
        assert sum(event["event"] == "market-x-auth-opened" for event in expiry_history) == 1, \
            "consumed approval replayed after auth-wait expiry"

        # A human-only incident with no exact runnable action offers no Approve.
        # A forged approval is rejected, while Dismiss remains available.
        manual_state = root / "manual-state"
        manual_queue = manual_state / "repair-queue"
        manual_queue.mkdir(parents=True)
        manual_log = root / "manual-notifications.jsonl"
        manual_env = {
            **env, "TOOL_STATUS_STATE": str(manual_state),
            "TOOL_STATUS_SCANNER": str(protected_scanner), "FAKE_CODEX_MODE": "manual",
            "FAKE_APPROVAL_MARKER": str(root / "manual-never"),
            "TOOL_STATUS_NOTIFICATION_LOG": str(manual_log),
        }
        manual_job = {**protected_job, "fingerprint": "fixture-manual"}
        (manual_queue / "manual.json").write_text(json.dumps(manual_job), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=manual_env, check=True)
        manual_requests = json.loads((manual_state / "repair-requests.json").read_text())
        assert len(manual_requests) == 1 and manual_requests[0]["status"] == "pending"
        assert manual_requests[0].get("actionable") is False, "human-only incident exposed Approve"
        assert manual_requests[0]["authorityStatus"] == "human-only"
        assert manual_requests[0]["requestedAction"] is None
        assert len(manual_log.read_text().splitlines()) == 1, "manual hand-off did not push once"
        manual_id = manual_requests[0]["id"]
        manual_decisions = manual_state / "repair-decisions"
        manual_decisions.mkdir(parents=True, exist_ok=True)
        (manual_decisions / "approve.json").write_text(json.dumps(
            decision_payload(manual_requests[0], "approve")
        ), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=manual_env, check=True)
        after_manual = json.loads((manual_state / "repair-requests.json").read_text())
        assert len(after_manual) == 1 and after_manual[0]["status"] == "pending", "blank approval was accepted"
        assert not list(manual_queue.glob("*.json")), "blank approval requeued a repair"
        manual_history = [json.loads(x) for x in (manual_state / "repair-history.jsonl").read_text().splitlines()]
        assert any(e["event"] == "decision-rejected-no-action" for e in manual_history), "blank approval rejection was not noted"
        assert len(manual_log.read_text().splitlines()) == 1, "approving a manual hand-off pushed again"
        # Dismiss on a manual card clears it without another push.
        (manual_decisions / "dismiss.json").write_text(json.dumps(
            decision_payload(manual_requests[0], "dismiss")
        ), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=manual_env, check=True)
        assert json.loads((manual_state / "repair-requests.json").read_text())[0]["status"] == "dismissed", \
            "dismiss did not clear the active grant"
        assert len(manual_log.read_text().splitlines()) == 1, "dismiss emitted another push"

        # A model-generated disallowed command is not a human decision. It stays
        # silent, executes nothing, and remains queued for bounded retry.
        reject_state = root / "reject-state"
        reject_queue = reject_state / "repair-queue"
        reject_queue.mkdir(parents=True)
        reject_env = {
            **env, "TOOL_STATUS_STATE": str(reject_state),
            "TOOL_STATUS_SCANNER": str(approval_scanner), "FAKE_CODEX_MODE": "reject",
            "FAKE_APPROVAL_MARKER": str(root / "reject-never"),
            "TOOL_STATUS_NOTIFICATION_LOG": str(root / "reject-notifications.jsonl"),
        }
        (reject_queue / "reject.json").write_text(
            json.dumps({**approval_job, "fingerprint": "fixture-reject"}), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=reject_env, check=True)
        assert not (reject_state / "repair-requests.json").exists(), "unsafe command created a human card"
        assert not Path(reject_env["TOOL_STATUS_NOTIFICATION_LOG"]).exists(), "unsafe command produced a push"
        assert not Path(reject_env["FAKE_APPROVAL_MARKER"]).exists(), "unsafe command executed"
        assert list(reject_queue.glob("*.json")), "unsafe command was not retained for silent retry"
        reject_history = [json.loads(x) for x in (reject_state / "repair-history.jsonl").read_text().splitlines()]
        assert any(e["event"] == "repair-stayed-silent" for e in reject_history), "silent retry was not noted"

        # A failed push delivery records no cooldown entry, so a genuine
        # notification is never silently suppressed for the whole window.
        fail_dir = root / "failnotify"
        fail_dir.mkdir()
        failing_notifier = fail_dir / "failing-notify"
        executable(failing_notifier, "#!/bin/bash\nexit 3\n")
        failnotify_state = root / "failnotify-state"
        (failnotify_state / "repair-queue").mkdir(parents=True)
        failnotify_env = {
            **env, "TOOL_STATUS_STATE": str(failnotify_state),
            "TOOL_STATUS_SCANNER": str(protected_scanner), "FAKE_CODEX_MODE": "approval",
            "FAKE_APPROVAL_MARKER": str(root / "failnotify-never"),
            "TOOL_STATUS_NOTIFIER": str(failing_notifier),
            "TOOL_STATUS_NOTIFY_COOLDOWN_SECONDS": "36000",
        }
        (failnotify_state / "repair-queue" / "j.json").write_text(
            json.dumps({**protected_job, "fingerprint": "fixture-failnotify"}), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=failnotify_env, check=True)
        ledger_path = failnotify_state / "repair-notify-ledger.json"
        assert (not ledger_path.exists()) or json.loads(ledger_path.read_text()) == {}, \
            "a failed delivery recorded a cooldown entry"

        # A per-incident push cooldown stops false spam: a flapping incident that
        # resolves and then re-fails on the same cause does not re-push.
        cooldown_state = root / "cooldown-state"
        cooldown_queue = cooldown_state / "repair-queue"
        cooldown_queue.mkdir(parents=True)
        cooldown_marker = root / "cooldown-marker"
        cooldown_log = root / "cooldown-notifications.jsonl"
        cooldown_env = {
            **env, "TOOL_STATUS_STATE": str(cooldown_state),
            "TOOL_STATUS_SCANNER": str(protected_scanner), "FAKE_CODEX_MODE": "approval",
            "FAKE_APPROVAL_MARKER": str(cooldown_marker),
            "TOOL_STATUS_NOTIFICATION_LOG": str(cooldown_log),
            "TOOL_STATUS_NOTIFY_COOLDOWN_SECONDS": "36000",
        }
        (cooldown_queue / "first.json").write_text(
            json.dumps({**protected_job, "fingerprint": "fixture-cooldown"}), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=cooldown_env, check=True)
        assert len(cooldown_log.read_text().splitlines()) == 1, "first escalation did not push"
        cooldown_marker.touch()
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=cooldown_env, check=True)
        assert json.loads((cooldown_state / "repair-requests.json").read_text())[0]["status"] == "resolved"
        cooldown_marker.unlink()
        reflap = {**protected_job, "fingerprint": "fixture-cooldown-2", "createdAt": "2026-07-17T05:00:00+00:00"}
        (cooldown_queue / "reflap.json").write_text(json.dumps(reflap), encoding="utf-8")
        subprocess.run(["/usr/bin/python3", str(WORKER)], env=cooldown_env, check=True)
        assert len(cooldown_log.read_text().splitlines()) == 1, "flapping incident re-pushed within cooldown"
        cooldown_history = [json.loads(x) for x in (cooldown_state / "repair-history.jsonl").read_text().splitlines()]
        assert any(e["event"] == "push-suppressed-cooldown" for e in cooldown_history), "cooldown suppression not recorded"

        # Disposable fake-Codex v5 lifecycle: approval mints one issue grant;
        # the first live strategy changes an unanticipated HOME path but leaves
        # the trusted incident unhealthy; the same grant retries with a second
        # strategy and the scanner then resolves it.  No real model/network or
        # external action is involved.
        e2e_home = root / "grant-e2e-home"
        e2e_state = root / "grant-e2e-state"
        (e2e_home / "Projects/UsageQueue").mkdir(parents=True)
        e2e_codex = root / "grant-e2e-codex"
        e2e_scanner = root / "grant-e2e-scanner.py"
        e2e_codex_home = root / "grant-e2e-codex-home"
        executable(e2e_codex, f"""#!/usr/bin/env python3
import json, sys, time
from pathlib import Path
home = Path({str(e2e_home)!r})
counter = home / "codex-attempts"
try:
    attempt = int(counter.read_text()) + 1
except (OSError, ValueError):
    attempt = 1
counter.write_text(str(attempt))
target = home / "Projects/UsageQueue" / ("unanticipated-first.txt" if attempt == 1 else "strategy-two.txt")
target.write_text("strategy %d\\n" % attempt)
time.sleep(0.8)
output = Path(sys.argv[sys.argv.index("--output-last-message") + 1])
output.write_text(json.dumps({{
    "schemaVersion": 5, "status": "repaired", "summary": "Applied local strategy %d." % attempt,
    "root_cause": "The fixture needed a second local strategy.", "proposed_fix": "Retry with the next local strategy.",
    "decision_impact": "preserves_decisions", "decision_basis": "The fixture grant owns this local objective.",
    "research_urls": [], "verification": ["fixture strategy completed"], "changed_paths": [str(target)],
    "proposed_paths": [], "escalation": "none", "requested_action": None, "hard_stop": None,
}}))
""")
        executable(e2e_scanner, """#!/usr/bin/env python3
import datetime, json, os
from pathlib import Path
home = Path(os.environ.get("TOOL_STATUS_HOME") or os.environ["HOME"])
try:
    attempt = int((home / "codex-attempts").read_text())
except (OSError, ValueError):
    attempt = 0
healthy = attempt >= 2
stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
item = {
    "id": "Background Job:Grant Lifecycle", "name": "Grant Lifecycle",
    "category": "Background Job", "state": "ok" if healthy else "fail",
    "headline": "Ready" if healthy else "Fixture still failing", "detail": "fixture",
    "evidence": "fixture scanner", "checkedAt": stamp, "fix": None,
    "causeCode": None if healthy else "fixture.failure", "causeParams": {},
    "notificationPolicy": "immediate", "deadlineAt": None,
}
print(json.dumps({"schemaVersion": 2, "generatedAt": stamp, "liveAuth": False, "items": [item]}))
""")
        e2e_keys = (
            "TOOL_STATUS_HOME", "TOOL_STATUS_STATE", "TOOL_STATUS_SCANNER", "TOOL_STATUS_CODEX",
            "TOOL_STATUS_REPAIR_SCHEMA", "TOOL_STATUS_DECISION_SCHEMA", "TOOL_STATUS_CANONICAL_CODEX_HOME",
        )
        saved_e2e_env = {key: os.environ.get(key) for key in e2e_keys}
        os.environ.update({
            "TOOL_STATUS_HOME": str(e2e_home), "TOOL_STATUS_STATE": str(e2e_state),
            "TOOL_STATUS_SCANNER": str(e2e_scanner), "TOOL_STATUS_CODEX": str(e2e_codex),
            "TOOL_STATUS_REPAIR_SCHEMA": str(SCHEMA), "TOOL_STATUS_DECISION_SCHEMA": str(DECISION_SCHEMA),
            "TOOL_STATUS_CANONICAL_CODEX_HOME": str(root / "grant-e2e-canonical"),
        })
        try:
            e2e_spec = importlib.util.spec_from_file_location("repair_grant_lifecycle_test", WORKER)
            e2e_live = importlib.util.module_from_spec(e2e_spec)
            assert e2e_spec.loader is not None
            e2e_spec.loader.exec_module(e2e_live)
            e2e_live.QUEUE.mkdir(parents=True, exist_ok=True)
            e2e_live.PENDING.mkdir(parents=True, exist_ok=True)
            e2e_live.snapshot_protected_controls = lambda: {}
            e2e_live.protected_control_check = lambda snapshot: (True, [], [])
            e2e_live.core_repair_invariants = lambda snapshot: (True, "fixture invariants")
            e2e_live.prepare_repair_codex_home = lambda: (e2e_codex_home.mkdir(parents=True, exist_ok=True) or e2e_codex_home)
            e2e_job = {
                "id": "Background Job:Grant Lifecycle", "fingerprint": "grant-lifecycle",
                "generation": "1" * 32, "revision": 1,
                "item": {
                    "id": "Background Job:Grant Lifecycle", "name": "Grant Lifecycle",
                    "category": "Background Job", "state": "fail", "causeCode": "fixture.failure", "causeParams": {},
                },
            }
            e2e_descriptor = e2e_live.issue_authority_descriptor(e2e_job)
            e2e_request = {
                "schemaVersion": 5, "id": "grant-lifecycle-request", "incidentID": e2e_job["id"],
                "fingerprint": e2e_job["fingerprint"], "generation": e2e_job["generation"], "revision": 1,
                "pendingKey": e2e_live.repair_key(e2e_job), "authorityDescriptor": e2e_descriptor,
                "authorityDigest": e2e_live.issue_authority_digest(e2e_descriptor), "authorityStatus": "active",
                "grantID": None, "status": "approved", "createdAt": e2e_live.iso(),
            }
            e2e_grant = e2e_live.create_issue_authority_grant(e2e_job, e2e_request)
            e2e_request["grantID"] = e2e_grant["grantID"]
            e2e_job["issueAuthorityGrant"] = e2e_grant
            e2e_live.atomic_json(e2e_live.REQUESTS, [e2e_request])
            e2e_queue_path = e2e_live.QUEUE / f"{e2e_live.repair_key(e2e_job)}.json"
            e2e_live.atomic_json(e2e_queue_path, e2e_job)
            e2e_live.process_active_issue_grant(e2e_queue_path, e2e_job)
            first_saved = e2e_live.load_issue_grants()[e2e_grant["grantID"]]
            assert first_saved["status"] == "active", "first unhealthy strategy terminalized the issue grant"
            assert first_saved["attempts"] == 1
            assert (e2e_home / "Projects/UsageQueue/unanticipated-first.txt").is_file()
            retry_job = e2e_live.load_json(e2e_queue_path, {})
            assert retry_job.get("issueAuthorityGrant", {}).get("grantID") == e2e_grant["grantID"]
            e2e_live.process_active_issue_grant(e2e_queue_path, retry_job)
            assert not e2e_queue_path.exists(), "healthy second strategy did not resolve the grant"
            assert (e2e_home / "Projects/UsageQueue/strategy-two.txt").is_file()
            resolved_request = next(value for value in e2e_live.load_requests() if value.get("id") == e2e_request["id"])
            assert resolved_request["status"] == "resolved"
        finally:
            for key, value in saved_e2e_env.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    print("autonomous repair checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
