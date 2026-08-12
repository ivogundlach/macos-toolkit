#!/usr/bin/env python3
"""Isolated real-scheduler acceptance test for weekly-system-improvement."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


HOME = Path.home()
LIVE_MEMORY = HOME / ".memory"
LIVE_STATE = HOME / ".local/state/weekly-system-improvement"
RUNS = LIVE_STATE / "acceptance-runs"
RESULT = LIVE_STATE / "acceptance-last.json"
SUCCESS_BUNDLE = LIVE_STATE / "acceptance-last-bundle"
PROGRAM = HOME / ".local/bin/weekly-system-improvement"
PROTECTED = [
    HOME / ".codex/AGENTS.md",
    HOME / ".codex/skills",
    LIVE_MEMORY / "current.md",
    LIVE_MEMORY / "index.md",
    LIVE_MEMORY / "ledger.ndjson",
    LIVE_MEMORY / "wiki",
]


class AcceptanceError(RuntimeError):
    pass


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, raw = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        os.write(fd, data)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(raw, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(raw)
        except FileNotFoundError:
            pass


def object_record(path: Path) -> dict:
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if path.is_symlink():
        return {"type": "symlink", "mode": mode, "target": os.readlink(path)}
    if path.is_dir():
        return {"type": "directory", "mode": mode}
    if path.is_file():
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
        return {"type": "file", "mode": mode, "sha256": digest.hexdigest(), "size": info.st_size}
    raise AcceptanceError(f"unsupported protected object: {path}")


def protected_manifest() -> dict:
    result: dict[str, dict] = {"schema": 1, "objects": {}}
    objects = result["objects"]
    for root in PROTECTED:
        if not root.exists() and not root.is_symlink():
            raise AcceptanceError(f"protected root is missing: {root}")
        paths = [root]
        if root.is_dir() and not root.is_symlink():
            paths.extend(sorted(root.rglob("*")))
        for path in paths:
            key = str(path.relative_to(HOME))
            objects[key] = object_record(path)
    return result


def expected_protected_keys() -> set[str]:
    keys: set[str] = set()
    for root in PROTECTED:
        paths = [root]
        if root.is_dir() and not root.is_symlink():
            paths.extend(sorted(root.rglob("*")))
        keys.update(str(path.relative_to(HOME)) for path in paths)
    return keys


def audit_manifest(value: dict) -> None:
    actual = set(value.get("objects", {}))
    expected = expected_protected_keys()
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise AcceptanceError(
            f"protected manifest coverage mismatch; missing={missing[:5]} extra={extra[:5]}")


def stable_manifest() -> dict:
    first = protected_manifest()
    time.sleep(0.2)
    second = protected_manifest()
    if first != second:
        raise AcceptanceError("protected files changed during manifest scan")
    audit_manifest(first)
    return first


def manifest_hash(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def remove_private_tree(path_root: Path, allowed_parent: Path) -> None:
    resolved_parent = allowed_parent.resolve()
    resolved_root = path_root.resolve()
    if resolved_root == resolved_parent or resolved_parent not in resolved_root.parents:
        raise AcceptanceError(f"refusing cleanup outside {allowed_parent}: {path_root}")
    for path in sorted(path_root.rglob("*"), reverse=True):
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if getattr(info, "st_flags", 0) and hasattr(os, "chflags"):
            os.chflags(path, 0, follow_symlinks=False)
        if not path.is_symlink():
            os.chmod(path, 0o700 if path.is_dir() else 0o600)
    shutil.rmtree(path_root)


def remove_success_run(run_root: Path) -> None:
    remove_private_tree(run_root, RUNS)


def save_success_bundle(run_root: Path, summary: dict, launch_snapshot: str) -> None:
    temporary = SUCCESS_BUNDLE.with_name(SUCCESS_BUNDLE.name + f".tmp.{os.getpid()}")
    if temporary.exists():
        remove_private_tree(temporary, LIVE_STATE)
    temporary.mkdir(parents=True, mode=0o700)
    report_id = summary["report_id"]
    sources = {
        "job.plist": run_root / "job.plist",
        "launchd.out": run_root / "launchd.out",
        "launchd.err": run_root / "launchd.err",
        "state.json": run_root / "state/state.json",
        "health.json": run_root / "state/health.json",
        "pending.flag": run_root / "state/pending.flag",
        "report.json": run_root / f"memory/audits/weekly-system-improvement/{report_id}.json",
        "report.md": run_root / f"memory/audits/weekly-system-improvement/{report_id}.md",
        "protected-before.json": run_root / "protected-before.json",
        "protected-after.json": run_root / "protected-after.json",
    }
    for name, source in sources.items():
        destination = temporary / name
        destination.write_bytes(source.read_bytes() if source.exists() else b"")
        os.chmod(destination, 0o600)
    (temporary / "launchctl.txt").write_text(launch_snapshot, encoding="utf-8")
    os.chmod(temporary / "launchctl.txt", 0o600)
    atomic_json(temporary / "protected-roots.json", {
        "schema": 1,
        "roots": [str(path.relative_to(HOME)) for path in PROTECTED],
        "enumerated_objects": summary["protected_object_count"],
        "missing": 0,
        "extra": 0,
    })
    atomic_json(temporary / "summary.json", summary)
    old = SUCCESS_BUNDLE.with_name(SUCCESS_BUNDLE.name + f".old.{os.getpid()}")
    if SUCCESS_BUNDLE.exists():
        os.replace(SUCCESS_BUNDLE, old)
    os.replace(temporary, SUCCESS_BUNDLE)
    directory_fd = os.open(LIVE_STATE, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    if old.exists():
        remove_private_tree(old, LIVE_STATE)


def make_fixture(run_root: Path) -> tuple[Path, Path]:
    memory = run_root / "memory"
    state = run_root / "state"
    distilled = memory / "raw/chat/distilled"
    distilled.mkdir(parents=True, mode=0o700)
    state.mkdir(parents=True, mode=0o700)
    (memory / "tools").mkdir(mode=0o700)
    (memory / "wiki").mkdir(mode=0o700)
    for name, content in (
        ("README.md", "# Isolated acceptance fixture\n"),
        ("index.md", "# Index\n"),
        ("current.md", "# Current\n"),
    ):
        (memory / name).write_text(content, encoding="utf-8")
    shutil.copy2(LIVE_MEMORY / "tools/memory-lint", memory / "tools/memory-lint")
    os.chmod(memory / "tools/memory-lint", 0o700)
    capture = distilled / "codex-2026-08-10-acceptance.md"
    capture.write_text(
        "---\ncreated_at: 2026-08-10T12:00:00-05:00\n---\n\n"
        "- [failure] A weekly audit encountered repeated tool retry friction.  "
        "(source_role: user; lead: no; evidence: \"repeated retry friction\"; conf 0.9)\n",
        encoding="utf-8",
    )
    ledger = {
        "id": "mem_acceptance_application",
        "type": "system-improvement-application",
        "status": "verified",
        "claim": "report=wsr_acceptance proposal=p1 observe_on=2020-01-01",
    }
    (memory / "ledger.ndjson").write_text(json.dumps(ledger) + "\n", encoding="utf-8")
    initial_state = {
        "schema": 1,
        "activated_at": "2020-01-01T00:00:00-06:00",
        "highest_slot": "2020-01-05",
    }
    (state / "state.json").write_text(json.dumps(initial_state) + "\n", encoding="utf-8")
    return memory, state


def verify_redirects(run_root: Path, memory: Path, state: Path) -> None:
    destinations = [
        memory / "audits/weekly-system-improvement",
        memory / "logs/weekly-system-improvement",
        state,
    ]
    resolved_root = run_root.resolve()
    for destination in destinations:
        resolved = destination.resolve()
        if resolved != resolved_root and resolved_root not in resolved.parents:
            raise AcceptanceError(f"writable destination escaped the isolated root: {destination}")


def install_plist(run_root: Path, memory: Path, state: Path, label: str) -> Path:
    plist = run_root / "job.plist"
    value = {
        "Label": label,
        "ProgramArguments": [str(PROGRAM), "--scheduled"],
        "ProcessType": "Background",
        "EnvironmentVariables": {
            "MEMORY_ROOT": str(memory),
            "WSI_STATE": str(state),
            "TZ": "America/Chicago",
        },
        "StandardOutPath": str(run_root / "launchd.out"),
        "StandardErrorPath": str(run_root / "launchd.err"),
    }
    with plist.open("wb") as handle:
        plistlib.dump(value, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(plist, 0o600)
    return plist


def launchctl(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["/bin/launchctl", *args], capture_output=True, text=True, check=check)


def wait_for_completion(state_path: Path, label: str, timeout: int = 900) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = json.loads(state_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            value = {}
        if value.get("last_status") == "success" and not value.get("in_progress"):
            return value
        if value.get("last_status") in {"failed", "deferred"} and not value.get("in_progress"):
            raise AcceptanceError(f"scheduled generation ended as {value.get('last_status')}: {value.get('last_error')}")
        status = launchctl("print", f"gui/{os.getuid()}/{label}", check=False)
        exit_match = re.search(r"last exit code = (-?\d+)", status.stdout)
        runs_match = re.search(r"runs = (\d+)", status.stdout)
        if (exit_match and runs_match and int(runs_match.group(1)) > 0
                and int(exit_match.group(1)) != 0 and not value.get("in_progress")):
            raise AcceptanceError(
                f"temporary LaunchAgent exited {exit_match.group(1)} before publishing state")
        time.sleep(1)
    raise AcceptanceError("temporary LaunchAgent timed out")


def verify_result(memory: Path, state_root: Path, state: dict) -> dict:
    report_id = state.get("active_report")
    if not isinstance(report_id, str) or not report_id.startswith("wsr_"):
        raise AcceptanceError("active report identifier is missing")
    audit = memory / "audits/weekly-system-improvement"
    json_path = audit / f"{report_id}.json"
    md_path = audit / f"{report_id}.md"
    for path in (json_path, md_path):
        info = path.stat()
        if stat.S_IMODE(info.st_mode) != 0o400:
            raise AcceptanceError(f"published report is not read-only: {path.name}")
        immutable = getattr(stat, "UF_IMMUTABLE", 0)
        if immutable and not (getattr(info, "st_flags", 0) & immutable):
            raise AcceptanceError(f"published report is not immutable: {path.name}")
        if info.st_size <= 0 or info.st_size > 1_000_000:
            raise AcceptanceError(f"published report size is invalid: {path.name}")
    report = json.loads(json_path.read_text(encoding="utf-8"))
    if report.get("schema") != 1 or report.get("report_id") != report_id:
        raise AcceptanceError("published report schema or identity is invalid")
    if report.get("runtime", {}).get("model") != "gpt-5.6-sol":
        raise AcceptanceError("published report did not use the real configured model")
    available = set(report.get("evidence_ids", []))
    for proposal in report.get("proposals", []):
        cited = set(proposal.get("evidence_ids", []))
        if not cited or not cited.issubset(available):
            raise AcceptanceError("published proposal contains an invalid evidence citation")
    if not report.get("verification_obligations_due"):
        raise AcceptanceError("fixture verification obligation was not published")
    if report.get("status") != "actionable":
        raise AcceptanceError("due obligation did not make the report actionable")
    pending = (state_root / "pending.flag").read_text(encoding="utf-8").strip()
    if pending != report_id:
        raise AcceptanceError("pending notice does not match the published report")
    health = json.loads((state_root / "health.json").read_text(encoding="utf-8"))
    if health.get("state") != "ok" or health.get("reason") != "last_run_succeeded":
        raise AcceptanceError("isolated health record does not show success")
    return {
        "report_id": report_id,
        "proposals": len(report.get("proposals", [])),
        "evidence": len(available),
        "model": report["runtime"]["model"],
        "pending": True,
    }


def main() -> int:
    if not PROGRAM.is_file():
        raise AcceptanceError(f"deployed command is missing: {PROGRAM}")
    RUNS.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(RUNS, 0o700)
    run_root = Path(tempfile.mkdtemp(prefix="run-", dir=RUNS))
    os.chmod(run_root, 0o700)
    label = f"com.ivogundlach.weekly-system-improvement-acceptance-{os.getpid()}"
    loaded = False
    succeeded = False
    launch_snapshot = ""
    started = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    try:
        before = stable_manifest()
        before_hash = manifest_hash(before)
        atomic_json(run_root / "protected-before.json", before)
        memory, state_root = make_fixture(run_root)
        verify_redirects(run_root, memory, state_root)
        plist = install_plist(run_root, memory, state_root, label)
        lint = subprocess.run(["/usr/bin/plutil", "-lint", str(plist)], capture_output=True, text=True)
        if lint.returncode != 0:
            raise AcceptanceError(f"temporary plist is invalid: {lint.stderr.strip()}")
        launchctl("bootstrap", f"gui/{os.getuid()}", str(plist))
        loaded = True
        launchctl("kickstart", "-k", f"gui/{os.getuid()}/{label}")
        state = wait_for_completion(state_root / "state.json", label)
        launch_snapshot = launchctl("print", f"gui/{os.getuid()}/{label}").stdout
        evidence = verify_result(memory, state_root, state)
        after = stable_manifest()
        after_hash = manifest_hash(after)
        atomic_json(run_root / "protected-after.json", after)
        if before != after:
            before_objects = before["objects"]
            after_objects = after["objects"]
            changed = sorted(
                key for key in set(before_objects) | set(after_objects)
                if before_objects.get(key) != after_objects.get(key)
            )
            atomic_json(run_root / "protected-diff.json", {"schema": 1, "changed": changed})
            raise AcceptanceError(
                "live protected-file manifest changed concurrently: "
                + ", ".join(changed[:8]))
        result = {
            "schema": 1,
            "status": "pass",
            "started_at": started,
            "finished_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
            "protected_manifest_sha256": before_hash,
            "protected_object_count": len(before["objects"]),
            "protected_after_sha256": after_hash,
            **evidence,
        }
        atomic_json(RESULT, result)
        save_success_bundle(run_root, result, launch_snapshot)
        succeeded = True
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except Exception as exc:
        failure = {
            "schema": 1,
            "status": "fail",
            "started_at": started,
            "finished_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
            "detail": f"{type(exc).__name__}: {exc}",
            "evidence_root": str(run_root),
        }
        atomic_json(run_root / "failure.json", failure)
        atomic_json(RESULT, failure)
        print(json.dumps(failure, indent=2, sort_keys=True), file=sys.stderr)
        return 1
    finally:
        if loaded:
            launchctl("bootout", f"gui/{os.getuid()}/{label}", check=False)
        if succeeded:
            remove_success_run(run_root)


if __name__ == "__main__":
    raise SystemExit(main())
