#!/usr/bin/env python3
"""Denial-boundary checks for the widened autonomous repair latitude.

Covers the three surfaces that gained latitude: which deterministic recipes may
run unattended, which executable an incident may rewrite, and which labels may be
restarted without approval.
"""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import stat
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
WORKER = HERE / "tool-status-repair-worker.py"


def load_worker(home: Path, state: Path):
    os.environ["TOOL_STATUS_HOME"] = str(home)
    os.environ["TOOL_STATUS_STATE"] = str(state)
    spec = importlib.util.spec_from_file_location("repair_worker_under_test", WORKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="repair-latitude-") as temporary:
        root = Path(temporary)
        home, state = root / "home", root / "state"
        (home / ".local/bin").mkdir(parents=True)
        state.mkdir(parents=True)

        for name in ("codex-auto-reset", "market-refresh", "notebooklm", "unregistered-tool"):
            path = home / ".local/bin" / name
            path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        (state / "registry.json").write_text(json.dumps({
            "schemaVersion": 1,
            "tools": [
                {"name": "codex-auto-reset", "binary": "codex-auto-reset", "addedBy": "agent"},
                {"name": "market-refresh", "binary": "market-refresh", "addedBy": "agent"},
            ],
        }), encoding="utf-8")

        worker = load_worker(home, state)
        assert worker.MODEL == "gpt-5.6-luna"
        assert worker.REASONING == "max"
        # Approved issue authority uses HOME as the workspace boundary rather
        # than rebuilding a guessed owner-scope path inventory.  The objective
        # and hard-stop prompt, not a predeclared candidate path, govern strategy
        # changes inside that broad local lane.
        broad_roots = worker.live_engineering_roots()
        assert broad_roots and broad_roots[0] == home, broad_roots
        broad_job = {
            "id": "Background Job:Broad Authority", "generation": "a" * 32, "revision": 1,
            "item": {"id": "Background Job:Broad Authority", "name": "Broad Authority",
                      "causeCode": "fixture.failure", "causeParams": {}},
        }
        broad_prompt = worker.live_repair_prompt(
            broad_job, {"authorityDescriptor": worker.issue_authority_descriptor(broad_job)}, root / "workspace",
        )
        assert "Paths, commands" in broad_prompt and "owner_scope" not in broad_prompt
        assert "Do not edit or weaken" in broad_prompt and "network access" in broad_prompt
        assert "hard_stop: null" in broad_prompt
        reset_item = {"name": "Codex Auto Reset", "id": "Background Job:Codex Auto Reset Health"}

        # --- A: deterministic recipe admission -------------------------------
        argv, timeout = worker.deterministic_recipe(
            reset_item, [str(home / ".local/bin/codex-auto-reset"), "--schedule"],
        )
        assert argv == [str(home / ".local/bin/codex-auto-reset"), "--schedule"], argv
        assert timeout == 240, f"retry budget needs a raised timeout, got {timeout}"

        for rejected in (
            [str(home / ".local/bin/codex-auto-reset")],                    # no subcommand
            [str(home / ".local/bin/codex-auto-reset"), "--dry-run"],       # consumes nothing but unlisted
            [str(home / ".local/bin/unregistered-tool"), "--schedule"],     # not a pinned executable
            ["/bin/rm", "-rf", str(home)],                                  # not a recipe at all
            [],
        ):
            assert worker.deterministic_recipe(reset_item, rejected)[0] is None, rejected

        # A spoofed basename must execute the pinned path, never the supplied one.
        spoof = root / "evil"
        spoof.mkdir()
        (spoof / "plutil").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        argv, _ = worker.deterministic_recipe(
            {"name": "Some Plist"}, [str(spoof / "plutil"), "-lint", str(root / "a.plist")],
        )
        assert argv is not None and argv[0] == "/usr/bin/plutil", argv

        # --- B: identity-bound executable scope ------------------------------
        assert worker.identity_executable(reset_item) == home / ".local/bin/codex-auto-reset"
        protected_reset = {**reset_item, "category": "Auth", "headline": "credential failure"}
        assert worker.identity_executable(protected_reset) == home / ".local/bin/codex-auto-reset"
        # Log text naming another tool must not confer write access to it.
        injected = {
            "name": "Codex Auto Reset",
            "detail": f"error: see {home}/.local/bin/unregistered-tool for details",
            "evidence": str(home / ".local/bin/unregistered-tool"),
        }
        roots, _ = worker.owner_scope(injected)
        assert home / ".local/bin/unregistered-tool" not in roots, roots
        # Unregistered identity grants nothing even when the file exists.
        assert worker.identity_executable({"name": "Unregistered Tool"}) is None
        # The monitor's own control plane is never a repair target.
        for guard in worker.SELF_PROTECTED_BINARIES:
            path = home / ".local/bin" / guard
            path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        (state / "registry.json").write_text(json.dumps({
            "schemaVersion": 1,
            "tools": [{"name": g, "binary": g, "addedBy": "agent"} for g in worker.SELF_PROTECTED_BINARIES],
        }), encoding="utf-8")
        for guard in worker.SELF_PROTECTED_BINARIES:
            pretty = guard.replace("-", " ").title()
            assert worker.identity_executable({"name": pretty}) is None, guard
            assert worker.identity_executable({"name": guard}) is None, guard
        # A LaunchAgent whose ProgramArguments point at the control plane must not
        # reach it either; owner_scope is the chokepoint that has to refuse.
        agents = home / "Library/LaunchAgents"
        agents.mkdir(parents=True, exist_ok=True)
        guard_label = "com.ivogundlach.tool-status-dashboard.repair"
        (agents / f"{guard_label}.plist").write_bytes(plistlib.dumps({
            "Label": guard_label,
            "ProgramArguments": [str(home / ".local/bin/tool-status-repair-worker")],
        }))
        guard_roots, _ = worker.owner_scope({"name": "Repair", "id": f"LaunchAgent:{guard_label}"})
        assert all(p.name not in worker.SELF_PROTECTED_BINARIES for p in guard_roots), guard_roots
        # --- B: a quoted project path is not a grant --------------------------
        usage = home / "Projects/UsageQueue"
        (usage / "app").mkdir(parents=True)
        (usage / "app/main.py").write_text("x = 1\n", encoding="utf-8")
        quoted = {
            "name": "Some Background Job", "category": "Background Job",
            "detail": f'traceback: File "{usage}/app/main.py", line 12',
        }
        assert worker.owner_scope(quoted)[0] == [], worker.owner_scope(quoted)[0]
        # Exact normalized scanner identities may claim their one unambiguous
        # project; generic or merely similar names still cannot.
        for exact in ("usage-queue", "Usage Queue"):
            item = {"name": exact, "category": "Background Job",
                    "detail": f'traceback: File "{usage}/app/main.py", line 12'}
            assert usage in worker.owner_scope(item)[0], exact
        for forged in ("queue", "Some Background Job"):
            item = {"name": forged, "category": "Background Job",
                    "detail": f'traceback: File "{usage}/app/main.py", line 12'}
            granted = [p for p in worker.owner_scope(item)[0] if p == usage]
            assert granted == [], f"{forged} promoted a quoted project path: {granted}"
        # The explicit rule remains the one intended way in.
        declared = {"name": "UsageQueue", "category": "App"}
        assert usage in worker.owner_scope(declared)[0], worker.owner_scope(declared)[0]
        # Grants match whole words, so a name that merely shares a prefix is refused
        # while a longer scanner name containing the whole token still resolves.
        for collision in ("UsageQueueExtra", "UsageQueueExtra Runtime"):
            assert usage not in worker.owner_scope({"name": collision})[0], collision
        assert usage in worker.owner_scope({"name": "UsageQueue Runtime"})[0]
        # Exclusions stay loose: over-matching only withholds authority.
        assert worker.owner_scope({"name": "UsageQueue", "category": "Auth"})[0] == []
        assert worker.owner_scope({"name": "UsageQueue mail sync"})[0] == []
        # A nested path deep inside the project is likewise not a grant.
        deep = {"name": "Some Job", "detail": f"{usage}/app/nested/deeper/file.py"}
        assert worker.owner_scope(deep)[0] == [], worker.owner_scope(deep)[0]

        # Protected incidents keep diagnosis-only scope.
        protected_roots, _ = worker.owner_scope(
            {"name": "Codex Auto Reset", "category": "Auth"},
        )
        assert protected_roots == [], protected_roots
        # A symlinked binary is not a rewrite target.
        link = home / ".local/bin/linked-tool"
        link.symlink_to(home / ".local/bin/codex-auto-reset")
        (state / "registry.json").write_text(json.dumps({
            "schemaVersion": 1,
            "tools": [{"name": "linked-tool", "binary": "linked-tool", "addedBy": "agent"}],
        }), encoding="utf-8")
        assert worker.identity_executable({"name": "Linked Tool"}) is None
        # Registry provenance is a trust boundary: auto entries, path-bearing
        # entries, and non-executable files cannot confer candidate scope.
        forged = home / ".local/bin/forged-tool"
        forged.write_text("not executable\n", encoding="utf-8")
        for entry in (
            {"name": "codex-auto-reset", "binary": "codex-auto-reset", "addedBy": "auto"},
            {"name": "forged", "binary": "../state/private", "addedBy": "agent"},
            {"name": "forged", "binary": "forged-tool", "addedBy": "agent"},
        ):
            (state / "registry.json").write_text(json.dumps({
                "schemaVersion": 1, "tools": [entry],
            }), encoding="utf-8")
            assert worker.registered_binaries() == set(), entry
        # A corrupt or missing registry grants nothing rather than falling back to
        # bare filesystem presence.
        for broken in ("{not json", "[]", json.dumps({"tools": "not-a-list"}), ""):
            (state / "registry.json").write_text(broken, encoding="utf-8")
            assert worker.identity_executable({"name": "Codex Auto Reset"}) is None, broken
        (state / "registry.json").unlink()
        assert worker.identity_executable({"name": "Codex Auto Reset"}) is None

        # --- C: restart allowlist and cross-job rate limit -------------------
        assert "com.ivogundlach.tool-status-dashboard.repair" not in worker.RESTART_SAFE_LABELS
        assert "com.ivo.school-sync" not in worker.RESTART_SAFE_LABELS
        assert "com.ivo.market.refresh" in worker.RESTART_SAFE_LABELS

        label = "com.ivo.market.refresh"
        assert worker.restart_budget_available(label)
        worker.record_restart(label)
        assert worker.restart_budget_available(label), "second restart should still be allowed"
        worker.record_restart(label)
        assert not worker.restart_budget_available(label), "third restart in window must be refused"
        # The ledger persists outside any job, so a new incident cannot reset it.
        assert json.loads((state / "restart-ledger.json").read_text())[label]

        # A synthesized restart (no explicit command) must not validate as one.
        job = {"item": {"id": f"LaunchAgent:{label}"}}
        assert worker.trusted_launchctl_followup(job, None) is not None, (
            "helper still synthesizes for the approved path"
        )
        assert worker.trusted_launchctl_followup(
            {"item": {"id": "LaunchAgent:com.thirdparty.thing"}}, ["launchctl", "kickstart", "-k", "x"],
        ) is None
        # Falsey non-None commands must not reach the synthesizing default.
        for empty in ([], "", {}):
            assert worker.trusted_launchctl_followup(job, empty) is None, empty
        # Only the forced-restart shape is a valid unattended follow-up: other verbs
        # and mismatched targets must be refused even for a safe label.
        target = f"gui/{os.getuid()}/{label}"
        for accepted in (["launchctl", "kickstart", target], ["launchctl", "kickstart", "-k", target]):
            assert worker.trusted_launchctl_followup(job, accepted) is not None, accepted
        for refused in (
            ["launchctl", "bootout", target],
            ["launchctl", "bootstrap", f"gui/{os.getuid()}", "/tmp/x.plist"],
            ["launchctl", "kill", "SIGKILL", target],
            ["launchctl", "kickstart", "-k", f"{target}.evil"],
            ["launchctl", "kickstart", "-k", f"system/{label}"],
        ):
            assert worker.trusted_launchctl_followup(job, refused) is None, refused
        # A spoofed executable path is neutralized by pinning, not by rejection:
        # the returned argv must always spawn /bin/launchctl.
        spoofed = worker.trusted_launchctl_followup(job, ["/tmp/evil/launchctl", "kickstart", "-k", target])
        assert spoofed is not None and spoofed[0] == "/bin/launchctl", spoofed
        # A corrupt ledger must refuse restarts rather than allow them.
        worker.RESTART_LEDGER.write_text("{not json", encoding="utf-8")
        assert not worker.restart_budget_available(label), "corrupt ledger must fail closed"
        worker.RESTART_LEDGER.unlink()
        assert worker.restart_budget_available(label), "absent ledger is an empty budget"

        # Model-deploy circuit keys use stable producer/cause fields only; changing
        # untrusted detail/evidence or the incident fingerprint cannot rotate them.
        breaker_job = {
            "id": "Background Job:Stable Producer", "fingerprint": "first",
            "item": {"name": "Stable Producer", "causeCode": "producer.structured",
                     "detail": "untrusted first", "evidence": "first"},
        }
        varied_breaker_job = {
            **breaker_job, "fingerprint": "second",
            "item": {**breaker_job["item"], "detail": "untrusted second", "evidence": "second"},
        }
        assert worker.model_deploy_key(breaker_job) == worker.model_deploy_key(varied_breaker_job)
        worker.record_model_deploy_failure(breaker_job)
        assert worker.model_deploy_breaker_tripped(varied_breaker_job)
        history = [
            json.loads(line) for line in worker.HISTORY.read_text(encoding="utf-8").splitlines()
        ]
        assert any(event["event"] == "model-deploy-breaker-recorded" for event in history)
        assert any(event["event"] == "model-deploy-breaker-tripped" for event in history)
        expired = worker.iso(
            worker.now() - worker.dt.timedelta(
                seconds=worker.MODEL_DEPLOY_BREAKER_SECONDS + 1,
            ),
        )
        worker.MODEL_DEPLOY_LEDGER.write_text(json.dumps({
            worker.model_deploy_key(breaker_job): [expired],
        }), encoding="utf-8")
        assert not worker.model_deploy_breaker_tripped(varied_breaker_job), (
            "expired model-deploy breaker did not reopen"
        )
        worker.MODEL_DEPLOY_LEDGER.write_text("{not json", encoding="utf-8")
        assert worker.model_deploy_breaker_tripped(breaker_job), (
            "corrupt model-deploy ledger failed open"
        )
        worker.record_model_deploy_failure(breaker_job)
        repaired_ledger = json.loads(worker.MODEL_DEPLOY_LEDGER.read_text(encoding="utf-8"))
        assert repaired_ledger.get(worker.MODEL_DEPLOY_CORRUPT_KEY), (
            "corrupt breaker recovery did not preserve a global fail-closed interval"
        )

        # Only the two explicit repair skills are exposed, and a nested symlink
        # escaping either source root rejects the entire Luna invocation context.
        fake_codex_home = root / "canonical-codex"
        fake_codex_home.mkdir()
        (fake_codex_home / "AGENTS.md").write_text("fixture rules\n", encoding="utf-8")
        malicious_skill = root / "malicious-skill"
        malicious_skill.mkdir()
        (malicious_skill / "SKILL.md").write_text("fixture\n", encoding="utf-8")
        (malicious_skill / "escape").symlink_to(root / "outside-skill")
        original_canonical = worker.CANONICAL_CODEX_HOME
        original_skills = worker.REPAIR_SKILLS
        worker.CANONICAL_CODEX_HOME = fake_codex_home
        worker.REPAIR_SKILLS = {"vibe-coding": malicious_skill}
        try:
            try:
                worker.prepare_repair_codex_home()
                raise AssertionError("skill symlink escape was accepted")
            except RuntimeError as error:
                assert "escapes its root" in str(error)
        finally:
            worker.CANONICAL_CODEX_HOME = original_canonical
            worker.REPAIR_SKILLS = original_skills

        # Test-only flags cannot activate the contained-fixture bypass when the
        # worker uses its normal live-state location. Genuine v3 eligibility is
        # evaluated by the normal policy and still requires a separate audit.
        previous_test_deploy = os.environ.get("TOOL_STATUS_TEST_ALLOW_MODEL_DEPLOY")
        previous_dry_run = os.environ.get("TOOL_STATUS_NOTIFICATION_DRY_RUN")
        os.environ["TOOL_STATUS_TEST_ALLOW_MODEL_DEPLOY"] = "1"
        os.environ["TOOL_STATUS_NOTIFICATION_DRY_RUN"] = "1"
        try:
            live_policy = load_worker(home, home / ".local/state/tool-status-dashboard")
            live_allowed, live_note = live_policy.autonomous_model_deploy_allowed(
                {
                    "id": "Background Job:UsageQueue",
                    "fingerprint": "hostile-test-flags",
                    "item": {"causeCode": "usagequeue.fixture"},
                },
                [{"path": str(usage / "app/main.py")}],
            )
            assert live_allowed, "normal v3 owned-code eligibility was unexpectedly denied"
            assert "Contained test fixture" not in live_note, (
                "test-only deployment bypass became reachable in live state"
            )
        finally:
            if previous_test_deploy is None:
                os.environ.pop("TOOL_STATUS_TEST_ALLOW_MODEL_DEPLOY", None)
            else:
                os.environ["TOOL_STATUS_TEST_ALLOW_MODEL_DEPLOY"] = previous_test_deploy
            if previous_dry_run is None:
                os.environ.pop("TOOL_STATUS_NOTIFICATION_DRY_RUN", None)
            else:
                os.environ["TOOL_STATUS_NOTIFICATION_DRY_RUN"] = previous_dry_run

        # The acceptance sandbox denies both filesystem writes and network egress.
        denied_target = root / "sandbox-write-must-not-exist"
        sandbox_probe = root / "sandbox-probe.sh"
        sandbox_probe.write_text(
            "#!/bin/bash\n"
            f"write_ok=0; printf bad > {str(denied_target)!r} 2>/dev/null && write_ok=1\n"
            "network_ok=0; /usr/bin/curl -m 1 -s https://example.com >/dev/null 2>&1 && network_ok=1\n"
            "[ \"$write_ok\" -eq 0 ] && [ \"$network_ok\" -eq 0 ]\n",
            encoding="utf-8",
        )
        sandbox_probe.chmod(sandbox_probe.stat().st_mode | stat.S_IXUSR)
        rc, _ = worker.run([
            "/usr/bin/sandbox-exec", "-p", worker.NO_NETWORK_NO_WRITE_PROFILE,
            str(sandbox_probe),
        ])
        assert rc == 0 and not denied_target.exists(), "acceptance sandbox allowed write or network"

        # --- A: launchctl operates only in the shapes the scanner emits -------
        domain = f"gui/{os.getuid()}"
        agent_item = {"id": f"LaunchAgent:{label}"}
        for accepted in (
            ["launchctl", "kickstart", f"{domain}/{label}"],
            ["launchctl", "kickstart", "-k", f"{domain}/{label}"],
            ["launchctl", "bootout", f"{domain}/{label}"],
            ["launchctl", "bootstrap", domain, str(home / f"Library/LaunchAgents/{label}.plist")],
        ):
            argv, _ = worker.deterministic_recipe(agent_item, accepted)
            assert argv is not None and argv[0] == "/bin/launchctl", accepted
        for refused in (
            ["launchctl", "kill", "SIGKILL", f"{domain}/{label}"],       # unintended verb
            ["launchctl", "kickstart", f"{domain}/{label}.evil"],        # substring collision
            ["launchctl", "kickstart", f"system/{label}"],               # wrong domain
            ["launchctl", "kickstart", "-k", f"{domain}/{label}", "x"],  # extra argument
            ["launchctl", "remove", label],
        ):
            assert worker.deterministic_recipe(agent_item, refused)[0] is None, refused

        # Promotion rejects a symlinked ancestor instead of following it to a
        # different writable tree. The same check runs immediately before each
        # backup/write/rename in the worker.
        swap_root = home / "Projects/SymlinkSwap"
        real_parent = swap_root / "real"
        real_parent.mkdir(parents=True)
        target = real_parent / "target.py"
        target.write_text("before\n", encoding="utf-8")
        alias_parent = swap_root / "alias"
        alias_parent.symlink_to(real_parent, target_is_directory=True)
        staged = root / "staged.py"
        staged.write_text("after\n", encoding="utf-8")
        symlink_change = {
            "path": str(alias_parent / "target.py"), "kind": "modified",
            "before": {"hash": worker.file_hash(target), "size": target.stat().st_size},
            "after": {"hash": worker.file_hash(staged), "size": staged.stat().st_size, "candidate": str(staged)},
        }
        try:
            worker.apply_changes([symlink_change], {"id": "symlink", "fingerprint": "swap"})
            raise AssertionError("symlinked ancestor was followed during promotion")
        except (OSError, worker.ConcurrentModificationError) as error:
            assert "symbolic" in str(error).casefold() or "symlink" in str(error).casefold(), error
        assert target.read_text(encoding="utf-8") == "before\n"

    print("repair latitude checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
