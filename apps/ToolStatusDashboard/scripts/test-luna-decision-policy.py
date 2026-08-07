#!/usr/bin/env python3
"""Targeted v3 checks for Luna authority, research, and decision gates."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
WORKER = HERE / "tool-status-repair-worker.py"


def load_worker(home: Path, state: Path):
    os.environ["TOOL_STATUS_HOME"] = str(home)
    os.environ["TOOL_STATUS_STATE"] = str(state)
    spec = importlib.util.spec_from_file_location("luna_decision_policy", WORKER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="luna-decision-policy-") as temporary:
        root = Path(temporary)
        home, state = root / "home", root / "state"
        project = home / "Projects/ExampleTool"
        project.mkdir(parents=True)
        state.mkdir(parents=True)
        source = project / "repair.py"
        source.write_text("VALUE = 'broken'\n", encoding="utf-8")
        contract = project / "tests/test_contract.py"
        contract.parent.mkdir()
        contract.write_text("assert EXPECTED_VALUE == 'fixed'\n", encoding="utf-8")
        generated = project / "build/output.bin"
        generated.parent.mkdir()
        generated.write_bytes(b"old")

        worker = load_worker(home, state)
        assert worker.MODEL == "gpt-5.6-luna"
        assert worker.REASONING == "max"
        assert worker.REPAIR_POLICY_VERSION == 5

        resolved, _ = worker.owner_scope({
            "name": "ExampleTool Runtime", "category": "Background Job",
        })
        assert project in resolved, resolved

        # v4 accepts exact existing project files proposed by Luna, but never a
        # generic home-directory class or a symlink escape.
        proposed = project / "extra.py"
        proposed.write_text("VALUE = 'extra'\n", encoding="utf-8")
        discovered, _ = worker.owner_scope(
            {"name": "Unresolved Example", "category": "Background Job"},
            [str(proposed)],
        )
        assert discovered == [proposed], discovered
        symlink = project / "escape.py"
        symlink.symlink_to(source)
        assert worker.discover_candidate_paths([str(symlink)]) == []
        for forbidden in (home / ".config", home / ".local/bin", home / "School", home / ".memory"):
            forbidden.mkdir(parents=True, exist_ok=True)
            candidate, _ = worker.owner_scope(
                {"name": "Unresolved Example", "category": "Background Job"},
                [str(forbidden)],
            )
            assert candidate == [], (forbidden, candidate)

        calls: list[list[str]] = []
        broker_environments: list[dict[str, str]] = []
        original_run = worker.run

        def fake_run(command, **kwargs):
            calls.append(command)
            broker_environments.append(kwargs.get("env") or {})
            return (22, "redirect refused")

        worker.run = fake_run
        try:
            evidence, records = worker.fetch_research_evidence(
                [
                    "https://example.com/steal",
                    "https://developer.apple.com/documentation/swift",
                ],
                root / "workspace",
            )
        finally:
            worker.run = original_run
        assert evidence == ""
        assert records[0]["status"] == "rejected"
        assert len(calls) == 1, "rejected host caused a network invocation"
        assert "--max-redirs" in calls[0] and calls[0][calls[0].index("--max-redirs") + 1] == "0"
        assert "-L" not in calls[0] and "--location" not in calls[0]
        assert "--disable" in calls[0]
        assert calls[0][calls[0].index("--proxy") + 1] == ""
        assert broker_environments[0]["NO_PROXY"] == "*"
        assert "HTTP_PROXY" not in broker_environments[0]
        assert broker_environments[0]["HOME"] != str(home)
        assert calls[0][-1].startswith("https://developer.apple.com/")

        candidate = root / "candidate.py"
        candidate.write_text("VALUE = 'fixed'\n", encoding="utf-8")
        change = {
            "path": str(source), "kind": "modified",
            "before": {"hash": worker.file_hash(source), "size": source.stat().st_size},
            "after": {
                "hash": worker.file_hash(candidate), "size": candidate.stat().st_size,
                "candidate": str(candidate),
            },
        }
        repair_result = {
            "decision_impact": "preserves_decisions",
            "decision_basis": "The existing test requires the fixed value.",
        }
        audit = {
            "decision_impact": "preserves_decisions",
            "decision_basis": "The unchanged test defines the intended value.",
            "confidence": "high",
            "contract_citations": [{
                "path": str(contract), "line": 1, "excerpt": "EXPECTED_VALUE == 'fixed'",
            }],
        }
        allowed, note = worker.validate_decision_audit(
            repair_result, audit, [project], [change],
        )
        assert allowed, note

        stale = {**audit, "contract_citations": [{
            "path": str(contract), "line": 1, "excerpt": "not on the line",
        }]}
        assert not worker.validate_decision_audit(
            repair_result, stale, [project], [change],
        )[0]
        self_citing = {**audit, "contract_citations": [{
            "path": str(source), "line": 1, "excerpt": "VALUE",
        }]}
        assert not worker.validate_decision_audit(
            repair_result, self_citing, [project], [change],
        )[0]

        deletion_changes = []
        for index in range(4):
            path = project / f"obsolete-{index}.py"
            path.write_text("old\n", encoding="utf-8")
            deletion_changes.append({
                "path": str(path), "kind": "deleted",
                "before": {"hash": worker.file_hash(path), "size": path.stat().st_size},
                "after": None,
            })
        assert worker.validate_change_policy(deletion_changes[:3], [project])[0]
        assert not worker.validate_change_policy(deletion_changes, [project])[0]
        deletion_job = {
            "id": "Background Job:ExampleTool", "fingerprint": "delete-rollback",
            "item": {"name": "ExampleTool"},
        }
        rollback = worker.apply_changes(deletion_changes[:1], deletion_job)
        assert not Path(deletion_changes[0]["path"]).exists()
        restored, conflicts = worker.rollback_changes(rollback)
        assert conflicts == [] and deletion_changes[0]["path"] in restored
        assert Path(deletion_changes[0]["path"]).read_text(encoding="utf-8") == "old\n"

        # A created path has an absent before-state. Rollback must remove the
        # newly created regular file (and must not mistake any existing object
        # for that absent state).
        created_target = project / "created-by-repair.py"
        created_candidate = root / "created-candidate.py"
        created_candidate.write_text("VALUE = 'created'\n", encoding="utf-8")
        created_change = {
            "path": str(created_target), "kind": "created", "before": None,
            "after": {
                "hash": worker.file_hash(created_candidate),
                "size": created_candidate.stat().st_size,
                "candidate": str(created_candidate),
            },
        }
        created_rollback = worker.apply_changes([created_change], deletion_job)
        assert created_target.is_file()
        assert not worker.matches_hash(created_target, None)
        created_restored, created_conflicts = worker.rollback_changes(created_rollback)
        assert created_conflicts == [] and str(created_target) in created_restored
        assert not created_target.exists(), "rollback retained a newly created path"

        manifest = worker.actual_manifest([project])
        generated.write_bytes(b"new")
        assert worker.scope_manifest_conflicts(manifest, [project]) == [], (
            "generated build output was included in the source conflict manifest"
        )
        source.write_text("VALUE = 'concurrent'\n", encoding="utf-8")
        assert str(source) in worker.scope_manifest_conflicts(manifest, [project])

        dependency = project / "package.json"
        dependency_candidate = root / "package.json"
        dependency.write_text('{"dependencies":{}}\n', encoding="utf-8")
        dependency_candidate.write_text('{"dependencies":{"x":"1"}}\n', encoding="utf-8")
        dependency_change = {
            "path": str(dependency), "kind": "modified",
            "before": {
                "hash": worker.file_hash(dependency), "size": dependency.stat().st_size,
            },
            "after": {
                "hash": worker.file_hash(dependency_candidate),
                "size": dependency_candidate.stat().st_size,
                "candidate": str(dependency_candidate),
            },
        }
        assert not worker.validate_change_policy([dependency_change], [project])[0]

        # Each approval-only category has an explicit negative boundary.
        protected_candidates = []
        for index, path in enumerate((
            project / ".env",
            project / "exports/people.csv",
            project / "data/people.json",
            project / "records.sqlite",
            project / "photo.jpg",
            project / "credentials/client.pem",
            project / ".netrc",
            project / "settings/access-token.conf",
            project / "uploads/people.blob",
            project / "tool-status-repair-worker.py",
            project / "tool-status-notify.py",
            home / ".local/bin/tool-status-notify",
        )):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("protected\n", encoding="utf-8")
            candidate_path = root / f"candidate-{index}-{path.name}"
            candidate_path.write_text("changed\n", encoding="utf-8")
            protected_candidates.append({
                "path": str(path), "kind": "modified",
                "before": {"hash": worker.file_hash(path), "size": path.stat().st_size},
                "after": {
                    "hash": worker.file_hash(candidate_path),
                    "size": candidate_path.stat().st_size,
                    "candidate": str(candidate_path),
                },
            })
        for protected_change in protected_candidates:
            assert not worker.validate_change_policy([protected_change], [project])[0], (
                f"protected path became autonomous: {protected_change['path']}"
            )

        redacted = worker.sanitize_persisted({
            "Authorization": "Bearer do-not-persist",
            "access_token": "do-not-persist",
            "nested": "Authorization: Bearer do-not-persist",
        })
        assert "do-not-persist" not in str(redacted), redacted
        assert worker.immutable_source_path(home / ".local/bin/tool-status-notify")
        assert worker.immutable_source_path(home / "Projects/ToolStatusDashboard/scripts/tool-status-notify.py")

        system_candidate = root / "system.plist"
        system_candidate.write_text("fixture\n", encoding="utf-8")
        system_change = {
            "path": "/Library/LaunchDaemons/com.example.fixture.plist",
            "kind": "created", "before": None,
            "after": {
                "hash": worker.file_hash(system_candidate),
                "size": system_candidate.stat().st_size,
                "candidate": str(system_candidate),
            },
        }
        assert not worker.validate_change_policy([system_change], [project])[0]

        overriding_result = {
            "decision_impact": "overrides_decision",
            "decision_basis": "This changes the storage migration contract.",
        }
        assert not worker.validate_decision_audit(
            overriding_result, audit, [project], [change],
        )[0], "an irreversible operating change passed the decision gate"

        public_action = ["curl", "https://example.com/publish"]
        assert worker.trusted_launchctl_followup(
            {"item": {"id": "Background Job:ExampleTool"}}, public_action,
        ) is None, "a model-requested external action became an unattended follow-up"

        # Crash recovery: a persisted transaction is restored before any new
        # diagnosis, and the recovery event is durable.
        crash_target = project / "crash.py"
        crash_target.write_text("VALUE = 'before'\n", encoding="utf-8")
        crash_candidate = root / "crash-candidate.py"
        crash_candidate.write_text("VALUE = 'applied'\n", encoding="utf-8")
        crash_change = {
            "path": str(crash_target), "kind": "modified",
            "before": {
                "hash": worker.file_hash(crash_target), "size": crash_target.stat().st_size,
            },
            "after": {
                "hash": worker.file_hash(crash_candidate),
                "size": crash_candidate.stat().st_size,
                "candidate": str(crash_candidate),
            },
        }
        crash_job = {
            "id": "Background Job:Crash Fixture", "fingerprint": "crash-fixture",
            "item": {"id": "Background Job:Crash Fixture", "name": "Crash Fixture"},
        }
        crash_rollback = worker.apply_changes([crash_change], crash_job)
        crash_job["transactionRollback"] = str(crash_rollback)
        crash_job["transactionChanges"] = [crash_change]
        crash_job_path = worker.QUEUE / "crash-fixture.json"
        crash_job_path.parent.mkdir(parents=True, exist_ok=True)
        worker.atomic_json(crash_job_path, crash_job)
        original_payload = worker.current_payload
        worker.current_payload = lambda: {"items": []}
        try:
            worker.process_job(crash_job_path, crash_job)
        finally:
            worker.current_payload = original_payload
        assert crash_target.read_text(encoding="utf-8") == "VALUE = 'before'\n"
        crash_history = worker.HISTORY.read_text(encoding="utf-8")
        assert "interrupted-transaction-recovered" in crash_history

        # A concurrent edit to an unchanged tracked source during deployment is
        # detected; rollback restores only the staged path and preserves the
        # concurrent edit.
        source.write_text("VALUE = 'before-deploy'\n", encoding="utf-8")
        contract.write_text("assert EXPECTED_VALUE == 'fixed'\n", encoding="utf-8")
        deploy_candidate = root / "deploy-candidate.py"
        deploy_candidate.write_text("VALUE = 'candidate'\n", encoding="utf-8")
        deploy_change = {
            "path": str(source), "kind": "modified",
            "before": {"hash": worker.file_hash(source), "size": source.stat().st_size},
            "after": {
                "hash": worker.file_hash(deploy_candidate),
                "size": deploy_candidate.stat().st_size,
                "candidate": str(deploy_candidate),
            },
        }
        deploy_snapshot = worker.actual_manifest([project])
        deploy_job = {
            "id": "Background Job:Deploy Fixture", "fingerprint": "deploy-fixture",
            "item": {"name": "Deploy Fixture"},
        }
        deploy_rollback = worker.apply_changes([deploy_change], deploy_job)
        contract.write_text("assert HUMAN_EDIT == 'preserved'\n", encoding="utf-8")
        applied_expected = worker.expected_applied_manifest(
            deploy_snapshot, [deploy_change],
        )
        assert str(contract) in worker.scope_manifest_conflicts(
            applied_expected, [project],
        )
        restored, conflicts = worker.rollback_changes(deploy_rollback)
        assert conflicts == []
        assert str(source) in restored
        assert source.read_text(encoding="utf-8") == "VALUE = 'before-deploy'\n"
        assert contract.read_text(encoding="utf-8") == "assert HUMAN_EDIT == 'preserved'\n"

        assert worker.unattended_restart_allowed(
            {"name": "ExampleTool", "category": "Background Job"},
            "com.ivogundlach.example-tool",
        )
        assert not worker.unattended_restart_allowed(
            {"name": "Example Mail", "category": "Background Job"},
            "com.ivogundlach.example-mail",
        )

        # A full v4 candidate plan is canonical and binds all operations, hashes,
        # limits, effects, and immutable constraints to one digest.
        plan_job = {"id": "Background Job:ExampleTool", "fingerprint": "plan", "generation": "a" * 32, "revision": 2}
        plan_candidate = root / "plan-candidate.py"
        plan_candidate.write_text("VALUE = 'planned'\n", encoding="utf-8")
        plan_change = {
            "path": str(source), "kind": "modified",
            "before": {"hash": worker.file_hash(source), "size": source.stat().st_size},
            "after": {"hash": worker.file_hash(plan_candidate), "size": plan_candidate.stat().st_size, "candidate": str(plan_candidate)},
        }
        plan, digest = worker.candidate_plan(plan_job, [plan_change], {"name": "ExampleTool"}, root / "workspace" / "candidate")
        assert plan["schemaVersion"] == 5 and plan["revision"] == 2
        assert digest == worker.canonical_plan_digest(plan)
        assert worker.plan_is_immutable_safe(plan)[0]
        request = {"id": "repair-plan", "incidentID": "Background Job:ExampleTool", "schemaVersion": 5, "generation": "a" * 32, "revision": 2, "authorityDigest": digest}
        decision = {"schemaVersion": 5, "requestID": "repair-plan", "incidentID": "Background Job:ExampleTool", "generation": "a" * 32, "revision": 2, "authorityDigest": digest, "decision": "approve"}
        assert worker.decision_matches_request(decision, request)[0]
        assert not worker.decision_matches_request({**decision, "revision": 1}, request)[0]
        assert not worker.decision_matches_request({"requestID": "repair-plan"}, request)[0]

        # Exact plan representation is fail-closed: no truncation and no combined
        # file-plus-command authority.
        too_many = [dict(plan_change, path=str(project / f"too-many-{index}.py")) for index in range(worker.MAX_CHANGED_FILES + 1)]
        try:
            worker.candidate_plan(plan_job, too_many, {"name": "ExampleTool"}, root / "workspace" / "candidate")
            raise AssertionError("oversized candidate plan was silently truncated")
        except ValueError as error:
            assert "cannot represent" in str(error)
        try:
            worker.candidate_plan(
                plan_job, [plan_change], {"name": "ExampleTool"}, root / "workspace" / "candidate",
                {"command": ["/usr/bin/open", "https://example.com"]},
            )
            raise AssertionError("combined file and command plan was accepted")
        except ValueError as error:
            assert "combine" in str(error)

        wrapper = project / "build.sh"
        wrapper.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        wrapper.chmod(0o755)
        effect_plan, _ = worker.candidate_plan(
            plan_job, [plan_change], {"name": "ExampleTool"}, root / "workspace" / "candidate",
        )
        assert effect_plan["effects"]["builds"][0]["argv"] == ["/bin/bash", str(wrapper)]
        wrapper.write_text("#!/bin/bash\nexit 7\n", encoding="utf-8")
        assert not worker.effects_match_current(effect_plan, [plan_change], {"name": "ExampleTool"})[0]

        # A wrapper changed by the approved candidate is bound from the staged
        # post-promotion bytes/mode, while an unrelated wrapper drift is still
        # rejected by the live effect recomputation.
        wrapper.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        wrapper_candidate = root / "build-wrapper-candidate.sh"
        wrapper_candidate.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        wrapper_candidate.chmod(0o755)
        wrapper_change = {
            "path": str(wrapper), "kind": "modified",
            "before": {"hash": worker.file_hash(wrapper), "size": wrapper.stat().st_size},
            "after": {
                "hash": worker.file_hash(wrapper_candidate), "size": wrapper_candidate.stat().st_size,
                "candidate": str(wrapper_candidate),
            },
        }
        wrapper_plan, _ = worker.candidate_plan(
            plan_job, [wrapper_change], {"name": "ExampleTool"}, root / "workspace" / "candidate",
        )
        expected_wrapper_hash = wrapper_plan["effects"]["builds"][0]["wrapperIdentity"]["sha256"]
        assert expected_wrapper_hash == worker.file_hash(wrapper_candidate)
        assert worker.effects_match_current(wrapper_plan, [wrapper_change], {"name": "ExampleTool"})[0]
        worker.atomic_copy(wrapper_candidate, wrapper)
        assert worker.effects_match_current(wrapper_plan, [wrapper_change], {"name": "ExampleTool"})[0]
        wrapper.write_text("#!/bin/bash\nexit 9\n", encoding="utf-8")
        assert not worker.effects_match_current(wrapper_plan, [wrapper_change], {"name": "ExampleTool"})[0]

        # An exact empty approved-effects object forbids discovering a wrapper
        # that did not exist when the request was displayed.
        late_wrapper = project / "late-build.sh"
        assert not late_wrapper.exists()
        deployment_calls: list[list[str]] = []
        original_deployment_run = worker.run
        worker.run = lambda command, **kwargs: (deployment_calls.append(command) or (0, ""))
        try:
            deployed, _ = worker.deploy_and_restart(
                [{"path": str(late_wrapper), "kind": "created"}],
                {"name": "ExampleTool"}, {},
            )
        finally:
            worker.run = original_deployment_run
        assert deployed and deployment_calls == [], f"empty approved effects discovered an unbound wrapper: deployed={deployed!r}, calls={deployment_calls!r}"

        # The pinned walk must not call Path.resolve or follow an ancestor that
        # was swapped to a symlink; the outside target remains untouched.
        outside = root / "outside"
        outside.mkdir()
        outside_target = outside / "victim.txt"
        outside_target.write_text("outside\n", encoding="utf-8")
        swapped = project / "swapped"
        swapped.symlink_to(outside, target_is_directory=True)
        original_resolve = Path.resolve
        Path.resolve = lambda self, *args, **kwargs: (_ for _ in ()).throw(AssertionError("pinned walk resolved a user path"))
        try:
            try:
                worker._open_pinned_parent(swapped / "victim.txt")
                raise AssertionError("symlinked ancestor was accepted by pinned walk")
            except OSError:
                pass
        finally:
            Path.resolve = original_resolve
        assert outside_target.read_text(encoding="utf-8") == "outside\n"

        # Non-auth approval grants durable issue authority. The staged candidate
        # is retained only as provenance; no exact candidate is applied.
        wrapper.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        wrapper.chmod(0o755)
        approval_job = {
            "id": "Background Job:ExampleTool", "fingerprint": "approved-plan",
            "generation": "b" * 32, "revision": 1,
            "item": {"id": "Background Job:ExampleTool", "name": "ExampleTool", "category": "Background Job"},
        }
        approval_candidate_root = worker.WORKSPACES / worker.repair_key(approval_job) / "candidate"
        approval_candidate_root.mkdir(parents=True, exist_ok=True)
        staged = approval_candidate_root / "home" / "Projects/ExampleTool/repair.py"
        staged.parent.mkdir(parents=True, exist_ok=True)
        staged.write_text("VALUE = 'approved'\n", encoding="utf-8")
        staged_wrapper = approval_candidate_root / "home" / "Projects/ExampleTool/build.sh"
        staged_wrapper.parent.mkdir(parents=True, exist_ok=True)
        staged_wrapper.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        staged_wrapper.chmod(0o755)
        staged_wrapper_hash = worker.file_hash(staged_wrapper)
        approval_change = {
            "path": str(source), "kind": "modified",
            "before": {"hash": worker.file_hash(source), "size": source.stat().st_size},
            "after": {"hash": worker.file_hash(staged), "size": staged.stat().st_size, "candidate": str(staged)},
        }
        approval_wrapper_change = {
            "path": str(wrapper), "kind": "modified",
            "before": {"hash": worker.file_hash(wrapper), "size": wrapper.stat().st_size},
            "after": {
                "hash": worker.file_hash(staged_wrapper), "size": staged_wrapper.stat().st_size,
                "candidate": str(staged_wrapper),
            },
        }
        approval_plan, approval_digest = worker.candidate_plan(
            approval_job, [approval_change, approval_wrapper_change], approval_job["item"], approval_candidate_root,
        )
        pending = worker.PENDING / f"{worker.repair_key(approval_job)}.json"
        worker.atomic_json(pending, approval_job)
        descriptor = worker.issue_authority_descriptor(approval_job)
        authority_digest = worker.issue_authority_digest(descriptor)
        approval_request = {
            "schemaVersion": 5, "id": "repair-approved-plan", "incidentID": approval_job["id"],
            "fingerprint": approval_job["fingerprint"], "generation": approval_job["generation"],
            "revision": 1, "pendingKey": worker.repair_key(approval_job),
            "planDigest": None, "authorityDescriptor": descriptor, "authorityDigest": authority_digest,
            "authorityStatus": "pending", "grantID": None, "candidateProvenance": {
                "diagnosticOnly": True, "candidateDigest": approval_digest, "changedFileCount": 2,
            }, "proposedPlan": None, "requestedAction": None,
            "status": "pending", "createdAt": worker.iso(), "updatedAt": worker.iso(),
        }
        worker.atomic_json(worker.REQUESTS, [approval_request])
        worker.DECISIONS.mkdir(parents=True, exist_ok=True)
        worker.atomic_json(worker.DECISIONS / "approve-plan.json", {
            "schemaVersion": 5, "incidentID": approval_job["id"], "generation": approval_job["generation"], "revision": 1,
            "authorityDigest": authority_digest, "requestID": approval_request["id"],
            "decision": "approve", "thoughts": "", "createdAt": worker.iso(),
        })
        original_apply = worker.apply_approved_candidate
        worker.apply_approved_candidate = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("legacy candidate applied"))
        try:
            worker.process_decisions()
        finally:
            worker.apply_approved_candidate = original_apply
        assert source.read_text(encoding="utf-8") != "VALUE = 'approved'\n"
        queue_job = worker.load_json(worker.QUEUE / f"{worker.repair_key(approval_job)}.json", {})
        assert queue_job.get("issueAuthorityGrant", {}).get("status") == "active"
        assert not queue_job.get("candidatePlan"), "staged candidate retained authority after approval"
        grants = worker.load_issue_grants()
        grant = next(value for value in grants.values() if value.get("requestID") == approval_request["id"])
        assert grant["authorityDescriptor"]["healthCheck"]["itemID"] == approval_job["item"]["id"]
        assert "operations" not in grant["authorityDescriptor"]
        assert grant["authorityDescriptor"]["lifetime"] == {"until": "trusted-health-or-revoked"}
        assert "expiresAt" not in grant and "maxAttempts" not in grant and "wallClockBudgetSeconds" not in grant
        assert any("issue-authority-approved" in line for line in worker.HISTORY.read_text(encoding="utf-8").splitlines())

        # An executing approved candidate is a recoverable transaction, not an
        # automatic browser-auth retry.
        recovery_target = project / "recovery.py"
        recovery_target.write_text("before\n", encoding="utf-8")
        recovery_job = {
            "id": "Background Job:Market Auth Recovery", "fingerprint": "recovery",
            "item": {"id": "Background Job:ExampleTool", "name": "ExampleTool", "causeCode": "fixture.failure"},
            "generation": "c" * 32, "revision": 1,
        }
        recovery_candidate_root = worker.WORKSPACES / worker.repair_key(recovery_job) / "candidate"
        recovery_candidate_root.mkdir(parents=True, exist_ok=True)
        recovery_candidate = recovery_candidate_root / "recovery.py"
        recovery_candidate.write_text("after\n", encoding="utf-8")
        recovery_change = {
            "path": str(recovery_target), "kind": "modified",
            "before": {"hash": worker.file_hash(recovery_target), "size": recovery_target.stat().st_size},
            "after": {"hash": worker.file_hash(recovery_candidate), "size": recovery_candidate.stat().st_size, "candidate": str(recovery_candidate)},
        }
        recovery_plan, recovery_digest = worker.candidate_plan(
            recovery_job, [recovery_change], recovery_job["item"], recovery_candidate_root,
        )
        recovery_rollback = worker.apply_changes([recovery_change], recovery_job)
        recovery_job.update({
            "approvalGranted": "exact grant", "approvedPlan": recovery_plan, "approvedAction": None,
            "approvalRequestID": "legacy-executing", "transactionState": "approved_candidate",
            "transactionRollback": str(recovery_rollback), "transactionChanges": [recovery_change],
        })
        recovery_pending = worker.PENDING / f"{worker.repair_key(recovery_job)}.json"
        worker.atomic_json(recovery_pending, recovery_job)
        recovery_request = {
            "id": "legacy-executing", "incidentID": recovery_job["id"], "pendingKey": worker.repair_key(recovery_job),
            "status": "executing", "schemaVersion": 4, "generation": recovery_job["generation"], "revision": 1,
            "planDigest": recovery_digest, "proposedPlan": recovery_plan, "requestedAction": None,
            "causeCode": "fixture.failure",
        }
        worker.atomic_json(worker.REQUESTS, [recovery_request])
        original_payload = worker.current_payload
        original_deploy = worker.deploy_and_restart
        recovery_health_calls = {"count": 0}
        # Increment the health counter on every check without changing the
        # request or revision; the first check fails and the post-apply check passes.
        def recovery_health():
            value = recovery_health_calls["count"]
            recovery_health_calls["count"] += 1
            return {"items": [{"id": recovery_job["id"], "state": "fail" if value == 0 else "ok"}]}
        worker.current_payload = recovery_health
        worker.deploy_and_restart = lambda changes, item, effects=None: (True, "fixture deployment")
        try:
            assert worker.recover_executing_request(recovery_pending, recovery_job, recovery_request)
        finally:
            worker.current_payload = original_payload
            worker.deploy_and_restart = original_deploy
        assert recovery_target.read_text(encoding="utf-8") == "after\n"
        recovered_request = worker.load_json(worker.REQUESTS, [])[0]
        assert recovered_request["status"] == "resolved"
        assert recovered_request["id"] == "legacy-executing" and recovered_request["revision"] == 1
        assert "market-x-auth-execution-reissued" not in worker.HISTORY.read_text(encoding="utf-8")

        # Crash (a): the approval was persisted before the first mutation. A
        # missing rollback journal is still a normal crash, so the same exact
        # candidate is applied without minting a revision or request.
        pre_target = project / "pre-mutation.py"
        pre_target.write_text("before\n", encoding="utf-8")
        pre_job = {
            "id": "Background Job:Pre Mutation", "fingerprint": "pre-mutation",
            "generation": "e" * 32, "revision": 1,
            "item": {"id": "Background Job:ExampleTool", "name": "ExampleTool"},
        }
        pre_root = worker.WORKSPACES / worker.repair_key(pre_job) / "candidate"
        pre_root.mkdir(parents=True, exist_ok=True)
        pre_candidate = pre_root / "pre-mutation.py"
        pre_candidate.write_text("after\n", encoding="utf-8")
        pre_change = {
            "path": str(pre_target), "kind": "modified",
            "before": {"hash": worker.file_hash(pre_target), "size": pre_target.stat().st_size},
            "after": {"hash": worker.file_hash(pre_candidate), "size": pre_candidate.stat().st_size, "candidate": str(pre_candidate)},
        }
        pre_plan, pre_digest = worker.candidate_plan(pre_job, [pre_change], pre_job["item"], pre_root)
        pre_pending = worker.PENDING / f"{worker.repair_key(pre_job)}.json"
        pre_job.update({"approvalGranted": "exact grant", "approvedPlan": pre_plan, "approvedAction": None,
                        "approvalRequestID": "pre-request", "transactionState": "approved_candidate",
                        "transactionRollback": str(worker.ROLLBACKS / worker.repair_key(pre_job)),
                        "transactionChanges": [pre_change]})
        pre_request = {
            "id": "pre-request", "incidentID": pre_job["id"], "pendingKey": worker.repair_key(pre_job),
            "status": "executing", "schemaVersion": 4, "generation": pre_job["generation"], "revision": 1,
            "planDigest": pre_digest, "proposedPlan": pre_plan, "requestedAction": None,
        }
        worker.atomic_json(pre_pending, pre_job)
        worker.atomic_json(worker.REQUESTS, [pre_request])
        pre_health_calls = {"count": 0}
        original_payload = worker.current_payload
        original_deploy = worker.deploy_and_restart
        # Use a stateful implementation so the health check is false before
        # and true after the exact replay.
        def pre_health():
            value = pre_health_calls["count"]
            pre_health_calls["count"] += 1
            return {"items": [{"id": pre_job["id"], "state": "fail" if value == 0 else "ok"}]}
        worker.current_payload = pre_health
        worker.deploy_and_restart = lambda changes, item, effects=None: (True, "fixture deployment")
        try:
            assert worker.recover_executing_request(pre_pending, pre_job, pre_request)
        finally:
            worker.current_payload = original_payload
            worker.deploy_and_restart = original_deploy
        assert pre_target.read_text(encoding="utf-8") == "after\n"
        pre_recovered = worker.load_json(worker.REQUESTS, [])[0]
        assert pre_recovered["status"] == "resolved" and pre_recovered["id"] == "pre-request" and pre_recovered["revision"] == 1

        # Crash (b): a journaled transaction applied only its first (created)
        # path. Recovery removes that partial path, restores the before-state,
        # and reapplies the same two-operation approval once.
        partial_modified = project / "partial-modified.py"
        partial_modified.write_text("before\n", encoding="utf-8")
        partial_created = project / "partial-created.py"
        partial_created.unlink(missing_ok=True)
        partial_job = {
            "id": "Background Job:Partial Candidate", "fingerprint": "partial-candidate",
            "generation": "f" * 32, "revision": 1,
            "item": {"id": "Background Job:ExampleTool", "name": "ExampleTool"},
        }
        partial_root = worker.WORKSPACES / worker.repair_key(partial_job) / "candidate"
        partial_root.mkdir(parents=True, exist_ok=True)
        partial_created_candidate = partial_root / "partial-created.py"
        partial_created_candidate.write_text("created\n", encoding="utf-8")
        partial_modified_candidate = partial_root / "partial-modified.py"
        partial_modified_candidate.write_text("modified\n", encoding="utf-8")
        partial_changes = [
            {"path": str(partial_created), "kind": "created", "before": None,
             "after": {"hash": worker.file_hash(partial_created_candidate), "size": partial_created_candidate.stat().st_size, "candidate": str(partial_created_candidate)}},
            {"path": str(partial_modified), "kind": "modified",
             "before": {"hash": worker.file_hash(partial_modified), "size": partial_modified.stat().st_size},
             "after": {"hash": worker.file_hash(partial_modified_candidate), "size": partial_modified_candidate.stat().st_size, "candidate": str(partial_modified_candidate)}},
        ]
        partial_plan, partial_digest = worker.candidate_plan(partial_job, partial_changes, partial_job["item"], partial_root)
        partial_rollback = worker.prepare_transaction(partial_changes, partial_job)
        worker.apply_changes([partial_changes[0]], partial_job, partial_rollback)
        assert partial_created.exists() and partial_modified.read_text(encoding="utf-8") == "before\n"
        partial_job.update({"approvalGranted": "exact grant", "approvedPlan": partial_plan, "approvedAction": None,
                            "approvalRequestID": "partial-request", "transactionState": "approved_candidate",
                            "transactionRollback": str(partial_rollback), "transactionChanges": partial_changes})
        partial_pending = worker.PENDING / f"{worker.repair_key(partial_job)}.json"
        partial_request = {
            "id": "partial-request", "incidentID": partial_job["id"], "pendingKey": worker.repair_key(partial_job),
            "status": "executing", "schemaVersion": 4, "generation": partial_job["generation"], "revision": 1,
            "planDigest": partial_digest, "proposedPlan": partial_plan, "requestedAction": None,
        }
        worker.atomic_json(partial_pending, partial_job)
        worker.atomic_json(worker.REQUESTS, [partial_request])
        partial_health_calls = {"count": 0}
        original_payload = worker.current_payload
        original_deploy = worker.deploy_and_restart
        def partial_health():
            value = partial_health_calls["count"]
            partial_health_calls["count"] += 1
            return {"items": [{"id": partial_job["id"], "state": "fail" if value == 0 else "ok"}]}
        worker.current_payload = partial_health
        worker.deploy_and_restart = lambda changes, item, effects=None: (True, "fixture deployment")
        try:
            assert worker.recover_executing_request(partial_pending, partial_job, partial_request)
        finally:
            worker.current_payload = original_payload
            worker.deploy_and_restart = original_deploy
        assert partial_created.read_text(encoding="utf-8") == "created\n"
        assert partial_modified.read_text(encoding="utf-8") == "modified\n"
        partial_recovered = worker.load_json(worker.REQUESTS, [])[0]
        assert partial_recovered["status"] == "resolved" and partial_recovered["id"] == "partial-request" and partial_recovered["revision"] == 1

        # Crash (c): command approval was claimed and commandStartedAt persisted
        # just before spawn. Recovery validates its bound executable and replays
        # the exact argv once; a second recovery marker cannot replay it again.
        command_marker = project / "command-marker"
        command = ["/usr/bin/touch", str(command_marker)]
        command_job = {
            "id": "Background Job:Command Recovery", "fingerprint": "command-recovery",
            "generation": "1" * 32, "revision": 1,
            "item": {"id": "Background Job:ExampleTool", "name": "ExampleTool"},
        }
        command_effects = worker.plan_effects([], command_job["item"])
        command_effects["command"] = worker.command_effect(command)
        command_plan = {
            "schemaVersion": 4, "generation": command_job["generation"], "revision": 1,
            "incidentID": command_job["id"], "candidateRoot": "", "operations": [],
            "limits": {"maxChangedFiles": worker.MAX_CHANGED_FILES, "maxChangedBytes": worker.MAX_CHANGED_BYTES, "maxDeletedFiles": worker.MAX_DELETED_FILES},
            "effects": command_effects, "exactCommand": command,
            "immutableConstraints": ["Only the exact displayed command may run once; no future discretion."],
        }
        command_request = {
            "id": "command-request", "incidentID": command_job["id"], "pendingKey": worker.repair_key(command_job),
            "status": "executing", "schemaVersion": 4, "generation": command_job["generation"], "revision": 1,
            "planDigest": worker.canonical_plan_digest(command_plan), "proposedPlan": command_plan,
            "requestedAction": {"kind": "command", "command": command},
        }
        command_job.update({"approvalGranted": "exact grant", "approvedAction": command_request["requestedAction"],
                            "approvedPlan": command_plan, "approvalRequestID": command_request["id"],
                            "commandStartedAt": worker.iso()})
        command_pending = worker.PENDING / f"{worker.repair_key(command_job)}.json"
        worker.atomic_json(command_pending, command_job)
        worker.atomic_json(worker.REQUESTS, [command_request])
        command_calls: list[list[str]] = []
        original_run = worker.run
        worker.run = lambda argv, **kwargs: (command_calls.append(argv) or (0, "fixture command"))
        try:
            assert worker.recover_executing_request(command_pending, command_job, command_request)
            command_queue = worker.QUEUE / f"{worker.repair_key(command_job)}.json"
            queued_command_job = worker.load_json(command_queue, {})
            queued_command_job.pop("commandCompletedAt", None)
            worker.atomic_json(command_queue, queued_command_job)
            assert worker.recover_executing_request(command_queue, queued_command_job, command_request)
        finally:
            worker.run = original_run
        assert command_calls == [command], command_calls
        command_recovered = worker.load_json(worker.REQUESTS, [])[0]
        assert command_recovered["status"] == "approved" and command_recovered["id"] == "command-request" and command_recovered["revision"] == 1

        # Legacy Market auth cards are upgraded in place to a nonce-bound v5
        # immutable Safari action before the UI can write a decision.
        auth_job = {
            "id": "Background Job:Legacy Market Auth", "fingerprint": "legacy-auth",
            "item": {"id": "Background Job:Legacy Market Auth", "name": "Market", "causeCode": "market.x_auth_required"},
            "repairPolicyVersion": 4,
        }
        auth_pending = worker.PENDING / f"{worker.repair_key(auth_job)}.json"
        worker.atomic_json(auth_pending, auth_job)
        legacy_request = {
            "id": "repair-legacy-auth", "incidentID": auth_job["id"],
            "pendingKey": worker.repair_key(auth_job), "schemaVersion": 1, "status": "pending",
        }
        assert worker.migrate_legacy_auth_request(auth_job, legacy_request, auth_pending)
        assert legacy_request["schemaVersion"] == 5
        assert isinstance(legacy_request["generation"], str) and len(legacy_request["generation"]) >= 16
        assert legacy_request["revision"] == 1
        assert legacy_request["requestedAction"]["command"] == worker.MARKET_X_LOGIN_COMMAND
        assert legacy_request["planDigest"] == worker.canonical_plan_digest(legacy_request["proposedPlan"])
        assert legacy_request["authorityDescriptor"].get("exactActionDigest") == worker.exact_action_plan_digest(
            legacy_request["proposedPlan"], legacy_request["requestedAction"]
        )
        auth_decision = {
            "schemaVersion": 5, "requestID": legacy_request["id"], "incidentID": legacy_request["incidentID"],
            "generation": legacy_request["generation"], "revision": legacy_request["revision"],
            "authorityDigest": legacy_request["authorityDigest"], "decision": "approve",
        }
        assert worker.decision_matches_request(auth_decision, legacy_request)[0]
        tampered_auth_action = {**legacy_request, "requestedAction": {
            **legacy_request["requestedAction"], "command": ["/usr/bin/open", "https://x.com/other"],
        }}
        assert not worker.decision_matches_request(auth_decision, tampered_auth_action)[0]
        tampered_auth_plan = {**legacy_request, "proposedPlan": {
            **legacy_request["proposedPlan"], "exactCommand": ["/usr/bin/open", "https://x.com/other"],
        }}
        assert not worker.decision_matches_request(auth_decision, tampered_auth_plan)[0]

        # Feedback creates a new approvable revision while preserving the same
        # generation nonce and conversation context; create_request must not roll
        # that revision back to the prior card.
        feedback_job = {
            "id": "Background Job:Feedback Fixture", "fingerprint": "feedback",
            "generation": "d" * 32, "revision": 2,
            "item": {"id": "Background Job:Feedback Fixture", "name": "Feedback Fixture", "causeCode": "fixture.failure"},
            "conversation": [{"role": "user", "text": "Please reconsider this.", "at": worker.iso()}],
        }
        old_feedback = {
            "id": "repair-feedback-old", "incidentID": feedback_job["id"], "pendingKey": "old-key",
            "generation": feedback_job["generation"], "revision": 1, "schemaVersion": 5,
            "planDigest": None, "authorityDigest": "a" * 64, "conversation": [{"role": "user", "text": "Please reconsider this.", "at": worker.iso()}],
            "status": "reconsidering", "createdAt": worker.iso(),
        }
        worker.atomic_json(worker.REQUESTS, [old_feedback])
        feedback_path = worker.QUEUE / "feedback.json"
        worker.atomic_json(feedback_path, feedback_job)
        worker.create_request(
            feedback_path, feedback_job,
            {"status": "needs_approval", "summary": "The revised review is ready.", "root_cause": "The worker needs your choice.", "proposed_fix": "Review the revised repair once.", "requested_action": None},
            "review required", "Review the revised repair",
        )
        refreshed = worker.load_requests()[0]
        assert refreshed["revision"] == 2, refreshed
        assert refreshed["generation"] == feedback_job["generation"]
        assert refreshed["conversation"] and refreshed["conversation"][0]["role"] == "user"

        # v5 authority is objective-bound, not path/command-bound: changing a
        # staged diagnostic candidate does not change the approval descriptor,
        # while changing the trusted incident objective does.
        descriptor_job = {
            "id": "Background Job:Descriptor Fixture", "fingerprint": "descriptor-fingerprint",
            "generation": "2" * 32, "revision": 3,
            "candidatePlan": {"operations": [{"path": str(source), "command": ["make", "old"]}]},
            "item": {"id": "Background Job:Descriptor Fixture", "name": "Descriptor Fixture",
                      "causeCode": "fixture.failure", "causeParams": {"target": "old"}},
        }
        descriptor_one = worker.issue_authority_descriptor(descriptor_job)
        descriptor_job["candidatePlan"] = {"operations": [{"path": "/tmp/unrelated", "command": ["make", "new"]}]}
        descriptor_two = worker.issue_authority_descriptor(descriptor_job)
        assert descriptor_one == descriptor_two
        assert worker.issue_authority_digest(descriptor_one) == worker.issue_authority_digest(descriptor_two)
        descriptor_keys = set()
        def collect_keys(value):
            if isinstance(value, dict):
                descriptor_keys.update(value)
                for nested in value.values():
                    collect_keys(nested)
            elif isinstance(value, list):
                for nested in value:
                    collect_keys(nested)
        collect_keys(descriptor_one)
        assert not descriptor_keys.intersection({"operations", "command", "path"})
        assert descriptor_one["lifetime"] == {"until": "trusted-health-or-revoked"}
        assert "maxSeconds" not in descriptor_one["lifetime"]
        descriptor_job["item"]["causeCode"] = "fixture.other"
        assert worker.issue_authority_digest(worker.issue_authority_descriptor(descriptor_job)) != worker.issue_authority_digest(descriptor_one)

        # The approved invocation starts at HOME and has no owner-scope path
        # inventory.  The prompt explicitly allows strategy/path changes inside
        # that objective while retaining the hard-stop boundary.
        approved_roots = worker.live_engineering_roots()
        assert approved_roots and approved_roots[0] == home
        authority_prompt = worker.live_repair_prompt(
            descriptor_job, {"authorityDescriptor": descriptor_one}, root / "workspace",
        )
        assert "Paths, commands" in authority_prompt
        assert "owner_scope" not in authority_prompt
        assert "School" in authority_prompt and "network access" in authority_prompt
        assert "hard_stop: null" in authority_prompt

        # A fresh healthy row may clear causeCode/causeParams.  It remains the
        # same bound item and must resolve rather than looking like a replacement
        # generation; a different active failure still fails closed.
        health_job = {
            "id": "Background Job:Health Fixture", "fingerprint": "health-fingerprint",
            "item": {"id": "Background Job:Health Fixture", "name": "Health Fixture",
                      "state": "fail", "causeCode": "fixture.failure", "causeParams": {"target": "x"}},
        }
        fresh_stamp = worker.iso()
        healthy_payload = {"generatedAt": fresh_stamp, "items": [{
            "id": health_job["id"], "name": "Health Fixture", "state": "ok",
            "causeCode": None, "causeParams": {}, "checkedAt": fresh_stamp,
        }]}
        healthy, note = worker.trusted_health_result(health_job, healthy_payload, worker.now() - worker.dt.timedelta(seconds=2))
        assert healthy, note
        changed_payload = {"generatedAt": fresh_stamp, "items": [{
            "id": health_job["id"], "name": "Health Fixture", "state": "fail",
            "causeCode": "fixture.other", "causeParams": {}, "checkedAt": fresh_stamp,
        }]}
        assert not worker.trusted_health_result(health_job, changed_payload, worker.now() - worker.dt.timedelta(seconds=2))[0]

        # Revocation polling must not mistake the normal healthy/no-cause row
        # emitted after repair for a replacement generation.  A different active
        # warn/fail cause still supersedes the grant.
        poll_descriptor = worker.issue_authority_descriptor(health_job)
        poll_grant = {
            "schemaVersion": 5, "grantID": "grant-poll-health", "requestID": "poll-health-request",
            "incidentID": health_job["id"], "generation": "6" * 32, "revision": 1,
            "authorityDescriptor": poll_descriptor, "authorityDigest": worker.issue_authority_digest(poll_descriptor),
            "status": "active", "fencingToken": "fence-poll",
        }
        poll_request = {
            "schemaVersion": 5, "id": "poll-health-request", "incidentID": health_job["id"],
            "generation": poll_grant["generation"], "revision": 1,
            "authorityDigest": poll_grant["authorityDigest"], "status": "approved",
        }
        worker.save_issue_grants({poll_grant["grantID"]: poll_grant})
        worker.atomic_json(worker.REQUESTS, [poll_request])
        original_current_payload = worker.current_payload
        worker.current_payload = lambda: healthy_payload
        try:
            assert worker.poll_issue_revocation(poll_grant, health_job) is None
            worker.current_payload = lambda: changed_payload
            assert worker.poll_issue_revocation(poll_grant, health_job) == "superseded"
        finally:
            worker.current_payload = original_current_payload

        # Lease fencing persists a PID/PGID/start identity, renews it, and safely
        # terminates only that verified process group.  A mismatched/reused PID is
        # never signalled by identifier alone.
        lease_grant = {
            "grantID": "grant-lease-regression", "requestID": "lease-request",
            "incidentID": "Background Job:Lease Fixture", "generation": "3" * 32,
            "status": "active", "fencingToken": "fence-lease",
        }
        lease_job = {"id": lease_grant["incidentID"], "fingerprint": "lease-fingerprint",
                     "generation": lease_grant["generation"], "revision": 1,
                     "item": {"id": lease_grant["incidentID"], "name": "Lease Fixture", "causeCode": "fixture.failure"}}
        worker.REPAIR_LEASES.mkdir(parents=True, exist_ok=True)
        lease = worker.acquire_issue_lease(lease_grant, lease_job)
        assert lease is not None
        child_process = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        try:
            assert worker.record_issue_child(lease_grant, lease, child_process)
            assert lease["child"]["pid"] == child_process.pid
            lease_path = worker.REPAIR_LEASES / f"{lease_grant['grantID']}.json"
            early_bytes = lease_path.read_bytes()
            assert worker.renew_issue_lease(lease_grant, lease)
            assert lease_path.read_bytes() == early_bytes, "early lease renewal rewrote durable state"
            assert worker.renew_issue_lease(lease_grant, lease)
            assert lease_path.read_bytes() == early_bytes, "repeated early lease renewal amplified writes"
            assert worker.parse_time(lease["expiresAt"]) > worker.now()
            mismatched = dict(lease)
            mismatched["child"] = {**lease["child"], "startAt": "reused-pid"}
            assert not worker.terminate_verified_issue_child(lease_grant, mismatched, reason="identity regression")
            assert child_process.poll() is None
            assert worker.terminate_verified_issue_child(lease_grant, lease, reason="lease regression cleanup")
            child_process.wait(timeout=5)
        finally:
            if child_process.poll() is None:
                child_process.kill()
                child_process.wait(timeout=5)
        lease_path = worker.REPAIR_LEASES / f"{lease_grant['grantID']}.json"
        lease_path.unlink(missing_ok=True)

        # An expired active grant with a verified orphan is fenced before durable
        # recovery requeues it.  The grant remains active, so one retry/no-progress
        # result and a scheduler restart cannot lose its authority.
        retry_job = {
            "id": "Background Job:Retry Fixture", "fingerprint": "retry-fingerprint",
            "generation": "4" * 32, "revision": 1,
            "item": {"id": "Background Job:Retry Fixture", "name": "Retry Fixture",
                      "state": "fail", "causeCode": "fixture.failure", "causeParams": {}},
        }
        retry_descriptor = worker.issue_authority_descriptor(retry_job)
        retry_request = {
            "schemaVersion": 5, "id": "retry-request", "incidentID": retry_job["id"],
            "fingerprint": retry_job["fingerprint"], "generation": retry_job["generation"], "revision": 1,
            "pendingKey": worker.repair_key(retry_job), "authorityDescriptor": retry_descriptor,
            "authorityDigest": worker.issue_authority_digest(retry_descriptor), "authorityStatus": "active",
            "grantID": "grant-retry-regression", "status": "approved", "createdAt": worker.iso(),
        }
        retry_grant = worker.create_issue_authority_grant(retry_job, retry_request)
        retry_grant["grantID"] = "grant-retry-regression"
        retry_grant["requestID"] = retry_request["id"]
        retry_grant["status"] = "active"
        orphan = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        try:
            orphan_identity = worker.process_identity(orphan.pid)
            assert orphan_identity is not None
            expired_lease = {
                "schemaVersion": 5, "grantID": retry_grant["grantID"], "incidentID": retry_job["id"],
                "generation": retry_job["generation"], "requestID": retry_request["id"],
                "fencingToken": "fence-orphan", "ownerPID": 999999, "startedAt": worker.iso(),
                "expiresAt": "2000-01-01T00:00:00+00:00", "child": {
                    "pid": orphan_identity["pid"], "pgid": orphan_identity["pgid"],
                    "startAt": orphan_identity["startAt"], "commandDigest": orphan_identity["commandDigest"],
                },
            }
            retry_grant["lease"] = expired_lease
            worker.atomic_json(worker.ISSUE_GRANTS, {retry_grant["grantID"]: retry_grant})
            worker.atomic_json(worker.REPAIR_LEASES / f"{retry_grant['grantID']}.json", expired_lease)
            worker.atomic_json(worker.REQUESTS, [retry_request])
            worker.recover_active_issue_grants()
            orphan.wait(timeout=5)
            retry_queue = worker.QUEUE / f"{worker.repair_key(retry_job)}.json"
            assert retry_queue.is_file(), "expired orphan grant was not durably requeued"
            assert not (worker.REPAIR_LEASES / f"{retry_grant['grantID']}.json").exists()
        finally:
            if orphan.poll() is None:
                orphan.kill()
                orphan.wait(timeout=5)

        # Protected-control restoration and journal redaction remain invariants
        # around the live lane; secrets never enter the append-only evidence.
        protected_fixture = root / "protected-control.fixture"
        protected_fixture.write_text("original\n", encoding="utf-8")
        original_controls = worker.protected_control_paths
        worker.protected_control_paths = lambda: [protected_fixture]
        try:
            protected_snapshot = worker.snapshot_protected_controls()
            protected_fixture.write_text("mutated\n", encoding="utf-8")
            safe, restored, flagged = worker.protected_control_check(protected_snapshot)
            assert safe and str(protected_fixture) in restored and not flagged
            assert protected_fixture.read_text(encoding="utf-8") == "original\n"
        finally:
            worker.protected_control_paths = original_controls
        worker.append_mutation_journal(lease_grant, "redaction-regression", command="Authorization: Bearer canary-secret")
        assert "canary-secret" not in worker.REPAIR_JOURNAL.read_text(encoding="utf-8")

        # Hard-stop output suspends the grant and does not mint an ordinary scope
        # approval request.  Feedback/stale/replay decisions remain CAS-bound.
        structured_stop = {
            "status": "needs_approval",
            "hard_stop": {
                "reason": "A required owner-only step is unavailable.",
                "human_action": "Complete the step yourself, then retry.",
            },
            "requested_action": {
                "kind": "config", "description": "The worker cannot continue.",
                "risk": "An owner decision is required.", "command": None,
            },
        }
        structured_guidance = worker.hard_stop_from_live_result(structured_stop)
        assert structured_guidance and "owner-only" in structured_guidance and "Complete the step" in structured_guidance
        hard_job = {
            "id": "Background Job:Hard Stop Fixture", "fingerprint": "hard-stop-fingerprint",
            "generation": "5" * 32, "revision": 1,
            "item": {"id": "Background Job:Hard Stop Fixture", "name": "Hard Stop Fixture",
                      "state": "fail", "causeCode": "fixture.failure", "causeParams": {}},
        }
        hard_descriptor = worker.issue_authority_descriptor(hard_job)
        hard_request = {
            "schemaVersion": 5, "id": "hard-request", "incidentID": hard_job["id"],
            "fingerprint": hard_job["fingerprint"], "generation": hard_job["generation"], "revision": 1,
            "authorityDescriptor": hard_descriptor, "authorityDigest": worker.issue_authority_digest(hard_descriptor),
            "authorityStatus": "pending", "grantID": None, "status": "pending", "createdAt": worker.iso(),
        }
        hard_grant = worker.create_issue_authority_grant(hard_job, hard_request)
        hard_job["issueAuthorityGrant"] = hard_grant
        hard_path = worker.QUEUE / f"{worker.repair_key(hard_job)}.json"
        worker.atomic_json(hard_path, hard_job)
        worker.atomic_json(worker.REQUESTS, [hard_request])
        original_current, original_scan, original_call = worker.current_payload, worker.trusted_scan_payload, worker.call_luna_live
        original_snapshot, original_check, original_invariants = worker.snapshot_protected_controls, worker.protected_control_check, worker.core_repair_invariants
        failing_item = {**hard_job["item"], "checkedAt": worker.iso()}
        worker.current_payload = lambda: {"generatedAt": worker.iso(), "items": [failing_item]}
        worker.trusted_scan_payload = lambda: ({"generatedAt": worker.iso(), "items": [failing_item]}, "fresh")
        worker.call_luna_live = lambda *args, **kwargs: ({
            "schemaVersion": 5, "status": "needs_approval", "summary": "credential needed",
            "hard_stop": {
                "reason": "A required owner-only step is unavailable.",
                "human_action": "Complete the step yourself, then retry.",
            },
            "requested_action": {"kind": "config", "description": "The worker cannot continue.", "risk": "An owner decision is required.", "command": None},
        }, 0, "", None)
        worker.snapshot_protected_controls = lambda: {}
        worker.protected_control_check = lambda snapshot: (True, [], [])
        worker.core_repair_invariants = lambda snapshot: (True, "fixture invariants")
        try:
            worker.process_active_issue_grant(hard_path, hard_job)
        finally:
            worker.current_payload, worker.trusted_scan_payload, worker.call_luna_live = original_current, original_scan, original_call
            worker.snapshot_protected_controls, worker.protected_control_check, worker.core_repair_invariants = original_snapshot, original_check, original_invariants
        hard_saved = next(value for value in worker.load_requests() if value.get("id") == "hard-request")
        assert hard_saved["status"] == "suspended-hard-stop"
        assert hard_saved["authorityStatus"] == "suspended-hard-stop"
        assert "owner-only" in hard_saved.get("humanAction", "")

        # A later trusted health tick resolves a suspended grant without asking
        # Luna to run again; an unhealthy result leaves the hard stop in place.
        hard_healthy_item = {
            **hard_job["item"], "state": "ok", "causeCode": None, "causeParams": {},
            "checkedAt": worker.iso(),
        }
        original_suspended_scan = worker.trusted_scan_payload
        worker.trusted_scan_payload = lambda: ({
            "generatedAt": worker.iso(), "items": [hard_healthy_item],
        }, "fresh")
        try:
            worker.process_suspended_issue_grant(hard_path, worker.load_json(hard_path, {}))
        finally:
            worker.trusted_scan_payload = original_suspended_scan
        assert not hard_path.exists(), "a freshly healthy hard-stop job was not resolved"
        hard_resolved = next(value for value in worker.load_requests() if value.get("id") == "hard-request")
        assert hard_resolved["status"] == "resolved"

        # Grant lifetime is an explicit health/revocation condition.  Old
        # timestamps and very large diagnostics never terminalize the active
        # grant; no-progress and per-attempt timeout both schedule the same
        # grant with bounded exponential backoff.
        def active_fixture(suffix: str):
            active_job = {
                "id": f"Background Job:Active Retry {suffix}",
                "fingerprint": f"active-{suffix}", "generation": (suffix * 32)[:32],
                "revision": 1,
                "item": {
                    "id": f"Background Job:Active Retry {suffix}", "name": f"Active Retry {suffix}",
                    "state": "fail", "causeCode": "fixture.failure", "causeParams": {},
                },
            }
            active_descriptor = worker.issue_authority_descriptor(active_job)
            active_request = {
                "schemaVersion": 5, "id": f"active-request-{suffix}", "incidentID": active_job["id"],
                "fingerprint": active_job["fingerprint"], "generation": active_job["generation"], "revision": 1,
                "pendingKey": worker.repair_key(active_job), "authorityDescriptor": active_descriptor,
                "authorityDigest": worker.issue_authority_digest(active_descriptor), "authorityStatus": "active",
                "grantID": None, "status": "approved", "createdAt": worker.iso(),
            }
            active_grant = worker.create_issue_authority_grant(active_job, active_request)
            active_request["grantID"] = active_grant["grantID"]
            active_job["issueAuthorityGrant"] = active_grant
            active_path = worker.QUEUE / f"{worker.repair_key(active_job)}.json"
            worker.atomic_json(active_path, active_job)
            requests = worker.load_requests()
            requests.append(active_request)
            worker.atomic_json(worker.REQUESTS, requests)
            return active_job, active_path, active_grant, active_request

        retry_job, retry_path, retry_grant, retry_request = active_fixture("r")
        retry_grant["attempts"] = 9999
        retry_grant["startedAt"] = "2000-01-01T00:00:00+00:00"
        worker.atomic_json(worker.ISSUE_GRANTS, {retry_grant["grantID"]: retry_grant})
        worker.atomic_json(retry_path, retry_job)
        original_retry = (
            worker.current_payload, worker.trusted_scan_payload, worker.call_luna_live,
            worker.snapshot_protected_controls, worker.protected_control_check,
            worker.core_repair_invariants,
        )
        retry_item = {**retry_job["item"], "checkedAt": worker.iso()}
        worker.current_payload = lambda: {"generatedAt": worker.iso(), "items": [retry_item]}
        worker.trusted_scan_payload = lambda: ({
            "generatedAt": worker.iso(), "items": [retry_item],
        }, "still failing")
        worker.snapshot_protected_controls = lambda: {}
        worker.protected_control_check = lambda snapshot: (True, [], [])
        worker.core_repair_invariants = lambda snapshot: (True, "fixture invariants")
        worker.call_luna_live = lambda *args, **kwargs: ({
            "schemaVersion": 5, "status": "needs_approval", "summary": "no progress",
            "changed_paths": [], "hard_stop": None,
        }, 0, "", None)
        try:
            worker.process_active_issue_grant(retry_path, retry_job)
            retry_saved = worker.load_issue_grants()[retry_grant["grantID"]]
            assert retry_saved["status"] == "active"
            assert retry_saved["attempts"] == 10000
            assert retry_saved["startedAt"] == "2000-01-01T00:00:00+00:00"
            assert worker.load_json(retry_path, {}).get("issueAuthorityGrant", {}).get("status") == "active"
            retry_request_saved = next(value for value in worker.load_requests() if value.get("id") == retry_request["id"])
            assert retry_request_saved["status"] == "approved"

            timeout_job, timeout_path, timeout_grant, timeout_request = active_fixture("t")
            timeout_item = {**timeout_job["item"], "checkedAt": worker.iso()}
            worker.current_payload = lambda: {"generatedAt": worker.iso(), "items": [timeout_item]}
            worker.trusted_scan_payload = lambda: ({
                "generatedAt": worker.iso(), "items": [timeout_item],
            }, "still failing")
            worker.call_luna_live = lambda *args, **kwargs: (None, 124, "timed out", "timeout")
            worker.process_active_issue_grant(timeout_path, timeout_job)
            timeout_saved = worker.load_issue_grants()[timeout_grant["grantID"]]
            assert timeout_saved["status"] == "active"
            timeout_request_saved = next(value for value in worker.load_requests() if value.get("id") == timeout_request["id"])
            assert timeout_request_saved["status"] == "approved"
            assert worker.load_json(timeout_path, {}).get("issueAuthorityGrant", {}).get("grantID") == timeout_grant["grantID"]
        finally:
            (
                worker.current_payload, worker.trusted_scan_payload, worker.call_luna_live,
                worker.snapshot_protected_controls, worker.protected_control_check,
                worker.core_repair_invariants,
            ) = original_retry

        changed_generation_job = {**retry_job, "generation": "z" * 32}
        assert not worker.active_grant_current(changed_generation_job, retry_grant)[0]
        changed_generation_path = worker.QUEUE / f"{worker.repair_key(changed_generation_job)}-generation.json"
        worker.atomic_json(changed_generation_path, changed_generation_job)
        worker.process_active_issue_grant(changed_generation_path, changed_generation_job)
        assert worker.load_issue_grants()[retry_grant["grantID"]]["status"] == "superseded"
        assert next(value for value in worker.load_requests() if value.get("id") == retry_request["id"])["status"] == "superseded"

        # Feedback before approval advances the conversation revision and
        # authority digest.  The old approval is ignored; the revised card stays
        # pending until a separately CAS-matching approval is supplied.
        feedback_v1_job = {
            "id": "Background Job:Feedback Before Approval", "fingerprint": "feedback-before",
            "generation": "f" * 32, "revision": 1,
            "item": {"id": "Background Job:Feedback Before Approval", "name": "Feedback Before Approval",
                      "state": "fail", "causeCode": "fixture.failure", "causeParams": {}},
        }
        feedback_v1_descriptor = worker.issue_authority_descriptor(feedback_v1_job)
        feedback_v1_request = {
            "schemaVersion": 5, "id": "feedback-before-request-v1",
            "incidentID": feedback_v1_job["id"], "fingerprint": feedback_v1_job["fingerprint"],
            "generation": feedback_v1_job["generation"], "revision": 1,
            "pendingKey": worker.repair_key(feedback_v1_job), "authorityDescriptor": feedback_v1_descriptor,
            "authorityDigest": worker.issue_authority_digest(feedback_v1_descriptor), "authorityStatus": "pending",
            "grantID": None, "status": "pending", "requestedAction": None, "proposedPlan": None,
            "planDigest": None, "createdAt": worker.iso(),
        }
        feedback_v1_path = worker.PENDING / f"{worker.repair_key(feedback_v1_job)}.json"
        worker.atomic_json(feedback_v1_path, feedback_v1_job)
        worker.atomic_json(worker.REQUESTS, worker.load_requests() + [feedback_v1_request])
        worker.atomic_json(worker.DECISIONS / "feedback-before-thoughts.json", {
            "schemaVersion": 5, "requestID": feedback_v1_request["id"],
            "incidentID": feedback_v1_request["incidentID"], "generation": feedback_v1_request["generation"],
            "revision": 1, "authorityDigest": feedback_v1_request["authorityDigest"],
            "decision": "thoughts", "thoughts": "Use a different local strategy.", "createdAt": worker.iso(),
        })
        worker.process_decisions()
        feedback_v2_path = worker.QUEUE / f"{worker.repair_key(feedback_v1_job)}.json"
        feedback_v2_job = worker.load_json(feedback_v2_path, {})
        assert feedback_v2_job.get("revision") == 2
        worker.create_request(
            feedback_v2_path, feedback_v2_job,
            {"status": "needs_approval", "summary": "Revised review is ready.",
             "root_cause": "The revised strategy is ready.", "proposed_fix": "Approve the revised local repair.",
             "requested_action": None},
            "revised approval", "Review the revised repair",
        )
        feedback_v2 = next(value for value in worker.load_requests() if value.get("incidentID") == feedback_v1_job["id"])
        assert feedback_v2["revision"] == 2
        assert feedback_v2["authorityDigest"] != feedback_v1_request["authorityDigest"]
        assert feedback_v2["status"] == "pending"
        worker.atomic_json(worker.DECISIONS / "feedback-before-old-approval.json", {
            "schemaVersion": 5, "requestID": feedback_v1_request["id"],
            "incidentID": feedback_v1_request["incidentID"], "generation": feedback_v1_request["generation"],
            "revision": 1, "authorityDigest": feedback_v1_request["authorityDigest"],
            "decision": "approve", "createdAt": worker.iso(),
        })
        worker.process_decisions()
        assert next(value for value in worker.load_requests() if value.get("incidentID") == feedback_v1_job["id"])["status"] == "pending"
        worker.atomic_json(worker.DECISIONS / "feedback-before-new-approval.json", {
            "schemaVersion": 5, "requestID": feedback_v2["id"],
            "incidentID": feedback_v2["incidentID"], "generation": feedback_v2["generation"],
            "revision": feedback_v2["revision"], "authorityDigest": feedback_v2["authorityDigest"],
            "decision": "approve", "createdAt": worker.iso(),
        })
        worker.process_decisions()
        feedback_approved_job = worker.load_json(worker.QUEUE / f"{worker.repair_key(feedback_v2_job)}.json", {})
        assert feedback_approved_job.get("issueAuthorityGrant", {}).get("status") == "active"

        valid_decision = {"schemaVersion": 5, "requestID": approval_request["id"], "incidentID": approval_request["incidentID"],
                          "generation": approval_request["generation"], "revision": approval_request["revision"],
                          "authorityDigest": approval_request["authorityDigest"], "decision": "stop"}
        for field, value in (("requestID", "wrong"), ("incidentID", "wrong"), ("generation", "wrong"),
                             ("revision", 99), ("authorityDigest", "0" * 64)):
            assert not worker.decision_matches_request({**valid_decision, field: value}, approval_request)[0]

    print("Luna decision-policy checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
