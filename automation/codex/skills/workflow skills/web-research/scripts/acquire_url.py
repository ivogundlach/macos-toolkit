#!/usr/bin/env python3
"""Acquire one public URL through a bounded evidence-preserving fallback chain."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
FETCH_PATH = SCRIPT_DIR / "fetch_url.py"
EXA_PATH = Path("/Users/YOUR_USERNAME/.codex/skills/tool skills/exa-search/scripts/exa_cli.py")
STATE_ROOT = Path.home() / ".local/state/web-research/acquisitions"
OWNED_DIR = re.compile(r"^\d{8}T\d{6}-[0-9a-f]{10}(?:-\d+)?$")

SPEC = importlib.util.spec_from_file_location("web_research_fetch_url", FETCH_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {FETCH_PATH}")
fetch_url = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetch_url)


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    encoded = (json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
        temporary = Path(handle.name)
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def visible_guard(path: Path) -> Path | None:
    resolved = path.expanduser().resolve(strict=False)
    for visible in (Path.home() / "Downloads", Path.home() / "Files"):
        try:
            resolved.relative_to(visible.resolve(strict=False))
            return visible
        except ValueError:
            pass
    return None


def prune_owned(root: Path, keep_days: int) -> None:
    if keep_days < 1 or not root.exists():
        return
    cutoff = time.time() - keep_days * 86400
    for child in root.iterdir():
        try:
            if (
                child.is_dir()
                and OWNED_DIR.fullmatch(child.name)
                and (child / "manifest.json").is_file()
                and child.stat().st_mtime < cutoff
            ):
                shutil.rmtree(child)
        except OSError:
            continue


def default_output(url: str, keep_days: int) -> Path:
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE_ROOT, 0o700)
    prune_owned(STATE_ROOT, keep_days)
    stamp = time.strftime("%Y%m%dT%H%M%S")
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:10]
    output = STATE_ROOT / f"{stamp}-{digest}"
    suffix = 1
    while output.exists():
        output = STATE_ROOT / f"{stamp}-{digest}-{suffix}"
        suffix += 1
    output.mkdir(mode=0o700)
    return output


def text_length(path: Path) -> int:
    try:
        return len(path.read_text(encoding="utf-8", errors="replace").strip())
    except OSError:
        return 0


def raw_assessment(metadata: dict[str, Any], text_path: Path) -> tuple[bool, str]:
    status = int(metadata.get("status") or 0)
    content_type = str(metadata.get("content_type") or "").lower()
    length = text_length(text_path)
    if status in {401, 403, 407}:
        return False, f"access_control_http_{status}"
    if status == 429:
        return False, "rate_limited_http_429"
    if not 200 <= status < 300:
        return False, f"non_success_http_{status}"
    if metadata.get("truncated"):
        return False, "raw_body_truncated"
    if metadata.get("likely_client_rendered_shell"):
        return False, "client_rendered_shell"
    if not metadata.get("text_extracted"):
        return False, "not_text_extractable"
    if "html" in content_type and length < 80 and int(metadata.get("body_bytes") or 0) > 1000:
        return False, "html_has_too_little_extracted_text"
    if length < 20:
        return False, "too_little_extracted_text"
    text = ""
    try:
        text = text_path.read_text(encoding="utf-8", errors="replace")[:4000].lower()
    except OSError:
        pass
    blocking_markers = (
        "checking your browser", "just a moment...", "enable javascript and cookies to continue",
        "access denied", "sign in to continue", "login required",
    )
    if length < 1500 and any(marker in text for marker in blocking_markers):
        return False, "delivery_or_access_wall"
    return True, "raw_http_evidence_complete"


def exa_content_length(payload: dict[str, Any]) -> int:
    response = payload.get("response") or {}
    lengths = []
    for result in response.get("results") or []:
        if not isinstance(result, dict):
            continue
        lengths.append(len(str(result.get("text") or "").strip()))
        lengths.extend(len(str(value).strip()) for value in (result.get("highlights") or []))
    return max(lengths, default=0)


def firecrawl_content_length(payload: Any) -> int:
    candidates: list[str] = []
    if isinstance(payload, dict):
        for key in ("markdown", "html", "rawHtml"):
            if isinstance(payload.get(key), str):
                candidates.append(payload[key])
        data = payload.get("data")
        if isinstance(data, dict):
            for key in ("markdown", "html", "rawHtml"):
                if isinstance(data.get(key), str):
                    candidates.append(data[key])
        elif isinstance(data, list):
            for item in data:
                if isinstance(item, dict):
                    candidates.extend(str(item.get(key) or "") for key in ("markdown", "html", "rawHtml"))
    return max((len(item.strip()) for item in candidates), default=0)


def run_command(command: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)


def terminal_manifest(
    *, url: str, output: Path, attempts: list[dict[str, Any]], selected: str | None,
    selected_evidence: str | None, raw_reason: str, keep_days: int,
) -> dict[str, Any]:
    route_changed = selected not in {None, "raw"}
    failed = selected is None
    if failed:
        dns_failure = any("DNS resolution failed" in str(attempt.get("detail", "")) for attempt in attempts)
        auth_failure = any(
            attempt.get("reason", "").startswith("access_control")
            or attempt.get("reason") == "delivery_or_access_wall"
            for attempt in attempts
        )
        if dns_failure:
            next_path = "repair_url_or_dns"
            repair = "Verify the hostname and local DNS/network resolution before retrying; browser escalation cannot repair DNS failure."
        elif auth_failure:
            next_path = "authenticated_browser"
            repair = "Open the URL in the existing signed-in browser surface, complete sign-in if required, and retry there."
        else:
            next_path = "playwright_or_in_app_browser"
            repair = "Try Playwright for rendered public state or the in-app browser when authentication/session state is required."
        notice = (
            f"All public acquisition paths failed for {url}. Attempted: "
            + ", ".join(str(item.get("method")) for item in attempts)
            + f". Next path: {next_path}. {repair}"
        )
    elif route_changed:
        next_path = None
        repair = None
        notice = f"Raw acquisition failed ({raw_reason}); recovered with {selected}. Disclose this route substitution."
    else:
        next_path = None
        repair = None
        notice = None
    return {
        "ok": not failed,
        "url": url,
        "selected_method": selected,
        "selected_evidence": selected_evidence,
        "route_changed": route_changed,
        "notify_user": bool(failed or route_changed),
        "notification": notice,
        "next_path": next_path,
        "repair": repair,
        "attempt_budget": 3,
        "attempts_used": len(attempts),
        "attempts": attempts,
        "output_dir": str(output),
        "retention_days": keep_days,
    }


def acquire(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    output = args.output_dir.expanduser().resolve() if args.output_dir else default_output(args.url, args.keep_days)
    if (visible := visible_guard(output)) is not None:
        raise ValueError(f"web evidence is backend state; output matched visible guard {visible}")
    output.mkdir(parents=True, exist_ok=True)
    os.chmod(output, 0o700)

    attempts: list[dict[str, Any]] = []
    selected: str | None = None
    selected_evidence: str | None = None
    raw_reason = "raw_not_attempted"

    raw_dir = output / "raw"
    try:
        metadata = fetch_url.fetch(
            args.url, raw_dir,
            "text/html,application/xhtml+xml,application/json,text/plain,application/pdf;q=0.8,*/*;q=0.5",
            args.max_bytes, args.timeout, args.max_redirects,
        )
        usable, raw_reason = raw_assessment(metadata, raw_dir / "text.txt")
        attempts.append({
            "method": "raw", "ok": usable, "reason": raw_reason,
            "status": metadata.get("status"), "evidence": str(raw_dir),
        })
        if usable:
            selected = "raw"
            selected_evidence = str(raw_dir)
    except Exception as error:  # normalized into a manifest; fetch helper owns specifics
        raw_reason = f"raw_exception:{type(error).__name__}"
        attempts.append({"method": "raw", "ok": False, "reason": raw_reason, "detail": str(error)[:1000]})

    if selected is None and not args.skip_exa and len(attempts) < args.attempt_budget:
        exa_file = output / "exa.json"
        command = [
            sys.executable, str(EXA_PATH), "--timeout", str(args.timeout),
            "--max-bytes", str(args.max_bytes), "--attempts", "1", "--output", str(exa_file),
            "contents", args.url, "--mode", "text", "--max-characters", str(args.max_characters),
        ]
        try:
            result = run_command(command, args.timeout + 5)
            if result.returncode == 0 and exa_file.is_file():
                payload = json.loads(exa_file.read_text(encoding="utf-8"))
                length = exa_content_length(payload)
                usable = length >= 80
                reason = "exa_content_complete" if usable else "exa_content_too_short"
                attempts.append({"method": "exa", "ok": usable, "reason": reason, "content_characters": length, "evidence": str(exa_file)})
                if usable:
                    selected, selected_evidence = "exa", str(exa_file)
            else:
                attempts.append({"method": "exa", "ok": False, "reason": "exa_command_failed", "exit_code": result.returncode, "detail": result.stderr[:2000]})
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            attempts.append({"method": "exa", "ok": False, "reason": f"exa_exception:{type(error).__name__}", "detail": str(error)[:1000]})

    if selected is None and not args.skip_firecrawl and len(attempts) < args.attempt_budget:
        firecrawl_file = output / "firecrawl.json"
        command = [
            "firecrawl", "scrape", args.url, "--format", "markdown,links", "--json",
            "--only-main-content", "--output", str(firecrawl_file),
        ]
        try:
            result = run_command(command, args.timeout + 30)
            if result.returncode == 0 and firecrawl_file.is_file():
                payload = json.loads(firecrawl_file.read_text(encoding="utf-8"))
                length = firecrawl_content_length(payload)
                usable = length >= 80
                reason = "firecrawl_content_complete" if usable else "firecrawl_content_too_short"
                attempts.append({"method": "firecrawl", "ok": usable, "reason": reason, "content_characters": length, "evidence": str(firecrawl_file)})
                if usable:
                    selected, selected_evidence = "firecrawl", str(firecrawl_file)
            else:
                attempts.append({"method": "firecrawl", "ok": False, "reason": "firecrawl_command_failed", "exit_code": result.returncode, "detail": result.stderr[:2000]})
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            attempts.append({"method": "firecrawl", "ok": False, "reason": f"firecrawl_exception:{type(error).__name__}", "detail": str(error)[:1000]})

    manifest = terminal_manifest(
        url=args.url, output=output, attempts=attempts, selected=selected,
        selected_evidence=selected_evidence, raw_reason=raw_reason, keep_days=args.keep_days,
    )
    manifest["attempt_budget"] = args.attempt_budget
    atomic_json(output / "manifest.json", manifest)
    return manifest, 0 if manifest["ok"] else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--max-bytes", type=int, default=10_000_000)
    parser.add_argument("--max-characters", type=int, default=100_000)
    parser.add_argument("--max-redirects", type=int, default=8)
    parser.add_argument("--attempt-budget", type=int, choices=(1, 2, 3), default=3)
    parser.add_argument("--keep-days", type=int, default=14)
    parser.add_argument("--skip-exa", action="store_true")
    parser.add_argument("--skip-firecrawl", action="store_true")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.timeout <= 0 or args.max_bytes < 1024 or args.max_characters < 1 or args.max_redirects < 0 or args.keep_days < 1:
        parser.error("timeouts and size limits must be positive; redirects non-negative")
    try:
        fetch_url.parse_public_url(args.url)
        manifest, exit_code = acquire(args)
    except (ValueError, fetch_url.FetchError) as error:
        parser.error(str(error))
    print(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
