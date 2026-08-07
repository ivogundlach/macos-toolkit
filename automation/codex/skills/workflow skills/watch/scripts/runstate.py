#!/usr/bin/env python3
"""Create and safely clean watch-owned temporary run directories."""
from __future__ import annotations

import argparse
import json
import shutil
import stat
import tempfile
import time
import uuid
from pathlib import Path


RUN_SCHEMA_VERSION = 1
RUN_ROOT = Path(tempfile.gettempdir()).resolve() / "watch-runs"
SENTINEL = ".watch-run.json"
STALE_AFTER_HOURS = 24


class CleanupError(RuntimeError):
    pass


def _root(root: Path | None = None) -> Path:
    resolved = (root or RUN_ROOT).resolve()
    resolved.mkdir(parents=True, exist_ok=True)
    resolved.chmod(0o700)
    return resolved


def create_run(root: Path | None = None) -> tuple[Path, str]:
    root_path = _root(root)
    run_id = uuid.uuid4().hex
    run_dir = root_path / run_id
    run_dir.mkdir(mode=0o700)
    payload = {
        "schema_version": RUN_SCHEMA_VERSION,
        "run_id": run_id,
        "created_at": time.time(),
        "run_dir": str(run_dir),
    }
    sentinel = run_dir / SENTINEL
    sentinel.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    sentinel.chmod(0o600)
    return run_dir, run_id


def _owned_run(path: str | Path, run_id: str | None = None, root: Path | None = None) -> tuple[Path, dict]:
    root_path = _root(root)
    raw = Path(path)
    if raw.is_symlink():
        raise CleanupError("run directory is a symlink")
    run_dir = raw.resolve(strict=True)
    try:
        run_dir.relative_to(root_path)
    except ValueError as exc:
        raise CleanupError(f"run directory is outside watch root {root_path}") from exc
    if run_dir.parent != root_path:
        raise CleanupError("run directory must be a direct child of the watch root")
    sentinel = run_dir / SENTINEL
    if sentinel.is_symlink() or not sentinel.is_file():
        raise CleanupError("watch sentinel is missing or unsafe")
    mode = sentinel.stat().st_mode
    if not stat.S_ISREG(mode):
        raise CleanupError("watch sentinel is not a regular file")
    try:
        payload = json.loads(sentinel.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CleanupError(f"watch sentinel is unreadable: {exc}") from exc
    expected = payload.get("run_id")
    if expected != run_dir.name or (run_id is not None and expected != run_id):
        raise CleanupError("watch sentinel run ID does not match")
    if Path(str(payload.get("run_dir", ""))).resolve() != run_dir:
        raise CleanupError("watch sentinel path does not match")
    return run_dir, payload


def cleanup_run(path: str | Path, run_id: str | None = None, root: Path | None = None) -> dict[str, object]:
    run_dir, payload = _owned_run(path, run_id=run_id, root=root)
    shutil.rmtree(run_dir)
    return {"status": "cleaned", "run_id": payload["run_id"], "run_dir": str(run_dir)}


def mark_keep(path: str | Path, run_id: str, root: Path | None = None) -> None:
    run_dir, payload = _owned_run(path, run_id=run_id, root=root)
    payload["keep"] = True
    sentinel = run_dir / SENTINEL
    sentinel.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    sentinel.chmod(0o600)


def cleanup_stale(max_age_hours: float = STALE_AFTER_HOURS, root: Path | None = None) -> list[str]:
    root_path = _root(root)
    cutoff = time.time() - max_age_hours * 3600
    cleaned: list[str] = []
    for child in root_path.iterdir():
        if child.is_symlink() or not child.is_dir():
            continue
        try:
            _, payload = _owned_run(child, root=root_path)
            if payload.get("keep") is True:
                continue
            if float(payload.get("created_at", 0)) >= cutoff:
                continue
            cleanup_run(child, root=root_path)
            cleaned.append(str(child))
        except (CleanupError, OSError, ValueError, TypeError):
            continue
    return cleaned


def main() -> int:
    parser = argparse.ArgumentParser(description="Safely clean watch-owned temporary runs.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    cleanup = subparsers.add_parser("cleanup")
    cleanup.add_argument("run_dir")
    cleanup.add_argument("--run-id")
    sweep = subparsers.add_parser("sweep")
    sweep.add_argument("--max-age-hours", type=float, default=STALE_AFTER_HOURS)
    args = parser.parse_args()
    try:
        if args.command == "cleanup":
            result = cleanup_run(args.run_dir, run_id=args.run_id)
        else:
            result = {"status": "ok", "cleaned": cleanup_stale(args.max_age_hours)}
        print(json.dumps(result, indent=2))
        return 0
    except CleanupError as exc:
        print(json.dumps({"status": "error", "error": str(exc)}, indent=2))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
