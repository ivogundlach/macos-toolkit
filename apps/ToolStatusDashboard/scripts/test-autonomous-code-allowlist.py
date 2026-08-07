#!/usr/bin/env python3
"""Pin the boundary that lets Luna repair an allowlisted diagnostic unattended.

Every check here exists because a specific way of getting this wrong was found
while building it, or was raised by an independent review of the design:

  * membership is by canonical path, so `..` and trailing slashes cannot smuggle
    a non-member in, and a directory can never become a member;
  * the control plane inside the same tree -- the corpus writers, the GitHub
    publish path, the secret gate, and the self-grading test suite -- stays out;
  * a ~/.local/bin symlink repointed at some OTHER allowlisted file does not
    inherit that file's authority, because the record names the binary allowed
    to reach it;
  * deployment is refused unless EVERY changed file is a member, so a candidate
    cannot ride one legitimate edit into the rest of the tree;
  * Auth is refused outright, allowlisted path or not;
  * and the contained rehearsal actually contains: a candidate that writes the
    corpus or opens a socket is stopped, and nothing lands on disk.
"""
from __future__ import annotations

import importlib.util
import shutil
import tempfile
from pathlib import Path

WORKER = Path(__file__).resolve().parent / "tool-status-repair-worker.py"


def load_worker():
    spec = importlib.util.spec_from_file_location("repair_worker", WORKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def change(path: Path, candidate: Path) -> dict:
    return {
        "path": str(path), "kind": "modified",
        "after": {"candidate": str(candidate), "size": 1, "hash": "h"},
    }


def main() -> int:
    w = load_worker()
    home = w.HOME
    tools = home / ".memory/tools"

    # --- membership ---------------------------------------------------------
    assert w.autonomous_code_entry(tools / "memory-index-check") is not None
    assert w.autonomous_code_entry(tools / ".." / "tools" / "memory-index-check") is not None
    for excluded in (
        "memory-secret-scan",      # the publish gate itself
        "memory-corpus-backup",    # pushes to a remote
        "memory-backup-verify",    # reaches the remote
        "memory-semantic-query",   # retrieval core, imported by writers
        "memory-retrieval-eval",   # spawns memory-semantic-query
        "memory-vector-build",     # corpus writer
        "memory-health-weekly",    # orchestrates all of the above
        "fusion.py",               # shared module imported by writers
    ):
        assert w.autonomous_code_entry(tools / excluded) is None, excluded
    assert w.autonomous_code_entry(home / ".memory/tests/run-all") is None, (
        "run-all grades the memory system, so it must not be able to repair itself"
    )
    for data in (".memory/raw", ".memory/wiki", ".memory/MEMORY.md", "School"):
        assert w.autonomous_code_entry(home / data) is None, data

    # --- registry identity --------------------------------------------------
    registered = w.registered_binaries()
    assert "memory-index-check" in registered, (
        "a symlinked allowlisted binary must survive registry validation"
    )
    assert "memory-secret-scan" not in registered, (
        "a symlinked binary outside the allowlist must stay dropped"
    )
    assert "memory-selftest" not in registered

    # --- scope --------------------------------------------------------------
    for tool in ("memory-index-check", "memory-coverage-drift"):
        roots, _ = w.owner_scope({
            "name": tool, "category": "Custom CLI",
            "headline": f"{tool} failed", "causeCode": "cli.failed",
        })
        assert roots == [tools / tool], f"{tool} -> {roots}"
    for denied in ("memory-secret-scan", "memory-selftest"):
        roots, _ = w.owner_scope({
            "name": denied, "category": "Custom CLI",
            "headline": f"{denied} failed", "causeCode": "cli.failed",
        })
        assert roots == [], f"{denied} must resolve no write scope, got {roots}"

    # --- deployment gate ----------------------------------------------------
    workspace = Path(tempfile.mkdtemp())
    stub = workspace / "stub"
    stub.write_text("#!/usr/bin/env python3\n")
    job = {
        "id": "Custom CLI:memory-index-check",
        "item": {
            "name": "memory-index-check", "category": "Custom CLI",
            "headline": "memory-index-check failed", "causeCode": "cli.failed",
        },
    }
    allowed, _ = w.autonomous_model_deploy_allowed(
        job, [change(tools / "memory-index-check", stub)])
    assert allowed, "an allowlisted-only candidate must be deployable"

    mixed, _ = w.autonomous_model_deploy_allowed(job, [
        change(tools / "memory-index-check", stub),
        change(tools / "memory-secret-scan", stub),
    ])
    assert not mixed, "one protected path must sink the whole candidate"

    corpus, _ = w.autonomous_model_deploy_allowed(
        job, [change(home / ".memory/raw/note.md", stub)])
    assert not corpus, "corpus data is never deployable"

    auth, _ = w.autonomous_model_deploy_allowed(
        {"id": "x", "item": {"name": "x", "category": "Auth"}},
        [change(tools / "memory-index-check", stub)])
    assert not auth, "Auth is refused even for an allowlisted path"

    # --- contained rehearsal ------------------------------------------------
    target = tools / "memory-index-check"

    clean_root = Path(tempfile.mkdtemp())
    clean = clean_root / "candidate"
    shutil.copy2(target, clean)
    passed, note = w.autonomous_code_preflight([change(target, clean)], clean_root)
    assert passed, f"an unmodified candidate must pass its own verification: {note}"

    hostile = [
        ("corpus write", "import pathlib\n"
                         "(pathlib.Path.home()/'.memory/raw/EVIL.md').write_text('x')\n",
         home / ".memory/raw/EVIL.md"),
        ("wiki write", "import pathlib\n"
                       "(pathlib.Path.home()/'.memory/wiki/EVIL.md').write_text('x')\n",
         home / ".memory/wiki/EVIL.md"),
        ("network", "import socket\nsocket.create_connection(('1.1.1.1', 80), 3)\n", None),
    ]
    for label, body, artifact in hostile:
        root = Path(tempfile.mkdtemp())
        candidate = root / "candidate"
        candidate.write_text(f"#!/usr/bin/env python3\n{body}print('ok')\n")
        passed, note = w.autonomous_code_preflight([change(target, candidate)], root)
        assert not passed, f"{label} candidate was not refused: {note}"
        if artifact is not None:
            assert not artifact.exists(), f"{label} candidate reached disk at {artifact}"

    broken_root = Path(tempfile.mkdtemp())
    broken = broken_root / "candidate"
    broken.write_text("#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n")
    passed, _ = w.autonomous_code_preflight([change(target, broken)], broken_root)
    assert not passed, "a candidate that breaks the real invocation must be refused"

    passed, _ = w.autonomous_code_preflight(
        [{"path": str(target), "kind": "deleted", "after": None}],
        Path(tempfile.mkdtemp()))
    assert not passed, "an allowlisted diagnostic may be repaired, not deleted"

    passed, _ = w.autonomous_code_preflight(
        [change(tools / "memory-secret-scan", clean)], Path(tempfile.mkdtemp()))
    assert not passed, "a non-member must never reach the rehearsal"

    # --- the rehearsal writes nothing real ---------------------------------
    # The tool's own run record must land in the throwaway HOME, not in the real
    # state directory, or a candidate could forge a success record that a later
    # health decision reads.
    state = home / ".local/state/memory-index-check"
    snapshot = (
        sorted((p.name, p.stat().st_mtime_ns) for p in state.glob("*"))
        if state.exists() else []
    )
    root = Path(tempfile.mkdtemp())
    candidate = root / "candidate"
    shutil.copy2(target, candidate)
    passed, _ = w.autonomous_code_preflight([change(target, candidate)], root)
    assert passed
    current = (
        sorted((p.name, p.stat().st_mtime_ns) for p in state.glob("*"))
        if state.exists() else []
    )
    assert snapshot == current, "the rehearsal wrote to the real state directory"
    assert (root / "diagnostic-memory-index-check/home/.local/state"
            / "memory-index-check/last-run.json").is_file(), (
        "the tool's run record should have landed in the throwaway HOME"
    )

    # --- the corpus fingerprint is content-based ---------------------------
    # Sizes and mtimes alone would miss a same-length replacement with the
    # timestamp restored, which is precisely what a smuggled corpus edit is.
    baseline = w.memory_corpus_fingerprint()
    probe = home / ".memory/raw/.autonomous-allowlist-probe.md"
    try:
        probe.write_text("a" * 64)
        stat = probe.stat()
        added = w.memory_corpus_fingerprint()
        assert added != baseline, "fingerprint missed a new corpus file"
        probe.write_text("b" * 64)
        import os as _os
        _os.utime(probe, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        assert w.memory_corpus_fingerprint() != added, (
            "fingerprint missed a same-size content swap with the mtime restored"
        )
    finally:
        probe.unlink(missing_ok=True)
    assert w.memory_corpus_fingerprint() == baseline

    print("autonomous code allowlist checks passed")
    print(f"allowlist: {sorted(p.name for p in w.AUTONOMOUS_CODE_FILES)}")
    print("containment evidence: corpus-write, wiki-write and socket candidates all refused, "
          "and none reached disk")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
