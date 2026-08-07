#!/usr/bin/env python3
"""Enumerate a YouTube playlist without exposing browser-cookie values."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


SCHEMA_VERSION = 1
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
DEFAULT_TIMEOUT = 120
AUTH_CODES = {
    "authentication_required",
    "bot_check",
    "cookie_tcc_denied",
    "cookie_read_failed",
    "public_access_forbidden",
}


def redact(value: str, limit: int = 1200) -> str:
    text = value.replace("\r", "")
    text = re.sub(
        r"(?i)(authorization)\s*[:=]\s*(?:bearer\s+)?[^\s;,]+",
        r"\1=[REDACTED]",
        text,
    )
    text = re.sub(
        r"(?i)(auth_token|ct0|cookie)\s*[:=]\s*[^\s;,]+",
        r"\1=[REDACTED]",
        text,
    )
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", text)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return " | ".join(lines[-8:])[:limit]


def failure(stderr: str, browser: str | None = None) -> dict[str, Any]:
    lowered = stderr.lower()
    diagnostic = redact(stderr) or "yt-dlp failed without diagnostic output"
    if browser == "safari" and any(
        token in lowered
        for token in ("operation not permitted", "permission denied", "full disk access")
    ):
        return {
            "code": "cookie_tcc_denied",
            "message": diagnostic,
            "repair_action": "Grant Full Disk Access to the invoking Codex/terminal process, then retry; automatic Firefox fallback is attempted when no browser was explicitly selected.",
        }
    if browser == "firefox" and any(
        token in lowered
        for token in ("cookies.sqlite", "firefox cookie database", "could not copy firefox")
    ):
        return {
            "code": "cookie_read_failed",
            "message": diagnostic,
            "repair_action": "Close Firefox so yt-dlp can copy cookies.sqlite, then retry.",
        }
    if browser and any(token in lowered for token in ("cookie", "keychain", "decrypt")):
        return {
            "code": "cookie_read_failed",
            "message": diagnostic,
            "repair_action": f"Confirm {browser.title()} is signed in, close it if its cookie database is locked, update yt-dlp, then retry.",
        }
    if "sign in to confirm" in lowered and "bot" in lowered:
        return {
            "code": "bot_check",
            "message": diagnostic,
            "repair_action": "Update yt-dlp and avoid repeated authenticated retries if the challenge persists because the signed-in account is exposed to the bot check.",
        }
    if "http error 403" in lowered or "403: forbidden" in lowered:
        if browser is None:
            return {
                "code": "public_access_forbidden",
                "message": diagnostic,
                "repair_action": "Retry through the automatic Safari-then-Firefox cookie path; update yt-dlp if authenticated access is also rejected.",
            }
        return {
            "code": "bot_check",
            "message": diagnostic,
            "repair_action": "Update yt-dlp and retry once with the alternate local browser; avoid repeated authenticated retries if YouTube continues returning 403.",
        }
    if any(
        token in lowered
        for token in (
            "private video",
            "members-only",
            "members only",
            "login required",
            "sign in",
            "authentication",
        )
    ):
        return {
            "code": "authentication_required",
            "message": diagnostic,
            "repair_action": "Confirm the selected browser is signed into the correct YouTube account, then retry.",
        }
    if any(
        token in lowered
        for token in (
            "timed out",
            "temporary failure in name resolution",
            "connection reset",
            "network is unreachable",
        )
    ):
        return {
            "code": "network_failed",
            "message": diagnostic,
            "repair_action": "Check connectivity and retry the same request.",
        }
    if any(token in lowered for token in ("unable to extract", "signature extraction", "nsig")):
        return {
            "code": "extractor_failed",
            "message": diagnostic,
            "repair_action": "Update yt-dlp with brew upgrade yt-dlp, then retry.",
        }
    if any(token in lowered for token in ("video unavailable", "playlist does not exist", "has been removed")):
        return {
            "code": "playlist_unavailable",
            "message": diagnostic,
            "repair_action": "Confirm the playlist URL/ID and that the selected account can access it.",
        }
    return {
        "code": "enumeration_failed",
        "message": diagnostic,
        "repair_action": "Inspect the structured attempts, update yt-dlp, and retry.",
    }


def resolve_ytdlp() -> str | None:
    override = os.environ.get("YTDLP")
    if override and Path(override).expanduser().is_file():
        return str(Path(override).expanduser())
    preferred = Path("/opt/homebrew/bin/yt-dlp")
    if preferred.is_file():
        return str(preferred)
    return shutil.which("yt-dlp")


def normalize_video_id(entry: dict[str, Any]) -> str | None:
    candidate = entry.get("id")
    if isinstance(candidate, str) and VIDEO_ID.fullmatch(candidate):
        return candidate
    raw = entry.get("webpage_url") or entry.get("url")
    if not isinstance(raw, str):
        return None
    if VIDEO_ID.fullmatch(raw):
        return raw
    try:
        parsed = urlparse(raw)
    except ValueError:
        return None
    host = parsed.netloc.lower().split(":", 1)[0]
    candidate = None
    if host in {"youtube.com", "www.youtube.com", "m.youtube.com"}:
        if parsed.path == "/watch":
            candidate = (parse_qs(parsed.query).get("v") or [None])[0]
        else:
            parts = [part for part in parsed.path.split("/") if part]
            if len(parts) >= 2 and parts[0] in {"shorts", "embed", "live"}:
                candidate = parts[1]
    elif host in {"youtu.be", "www.youtu.be"}:
        parts = [part for part in parsed.path.split("/") if part]
        candidate = parts[0] if parts else None
    return candidate if isinstance(candidate, str) and VIDEO_ID.fullmatch(candidate) else None


def run_attempt(
    binary: str,
    source: str,
    browser: str | None,
    timeout: int,
    run_dir: Path,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    command = [binary]
    if browser:
        command.extend(["--cookies-from-browser", browser])
    command.extend(["--flat-playlist", "--dump-single-json", "--no-warnings", "--", source])
    env = {**os.environ, "TMPDIR": str(run_dir)}
    try:
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, {
            "code": "network_timeout",
            "message": f"yt-dlp exceeded the {timeout}-second enumeration timeout.",
            "repair_action": "Check connectivity and retry; increase --timeout only when the playlist is known to be unusually large.",
        }
    except OSError as exc:
        return None, {
            "code": "yt_dlp_launch_failed",
            "message": redact(str(exc)),
            "repair_action": "Verify the resolved yt-dlp executable and retry.",
        }
    if proc.returncode != 0:
        return None, failure(proc.stderr, browser)
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return None, {
            "code": "invalid_ytdlp_json",
            "message": f"yt-dlp returned invalid playlist JSON: {exc}",
            "repair_action": "Update yt-dlp and retry.",
        }
    if not isinstance(payload, dict):
        return None, {
            "code": "invalid_ytdlp_json",
            "message": "yt-dlp returned a non-object playlist payload.",
            "repair_action": "Update yt-dlp and retry.",
        }
    return payload, None


def enumerate_playlist(args: argparse.Namespace) -> dict[str, Any]:
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "notify_user": False,
        "source": args.source,
        "network_performed": False,
        "authenticated_read_performed": False,
        "browser_path": None,
        "attempts": [],
        "degradation_reasons": [],
        "result": None,
    }
    binary = resolve_ytdlp()
    result["yt_dlp"] = binary
    if not binary:
        result.update({
            "status": "error",
            "notify_user": True,
            "error": {
                "code": "yt_dlp_missing",
                "message": "yt-dlp is not installed or not executable.",
                "repair_action": "Install yt-dlp with brew install yt-dlp, then retry.",
            },
        })
        return result
    if args.mode == "auth" and args.no_browser_cookies:
        result.update({
            "status": "error",
            "notify_user": True,
            "error": {
                "code": "authentication_required",
                "message": "Watch Later requires browser-cookie authentication.",
                "repair_action": "Retry without --no-browser-cookies while signed into YouTube in Safari or Firefox.",
            },
        })
        return result

    browsers = [args.browser] if args.browser else ["safari", "firefox"]
    attempts: list[str | None] = browsers if args.mode == "auth" else [None]
    if args.mode == "public" and not args.no_browser_cookies:
        attempts.extend(browsers)

    payload = None
    last_error = None
    with tempfile.TemporaryDirectory(prefix="jdownloader-playlist-") as temp:
        run_dir = Path(temp)
        os.chmod(run_dir, 0o700)
        for browser in attempts:
            method = "browser_cookies" if browser else "public"
            result["network_performed"] = True
            raw, error = run_attempt(binary, args.source, browser, args.timeout, run_dir)
            event: dict[str, Any] = {"method": method, "browser": browser}
            if raw is not None:
                event["status"] = "ok"
                result["attempts"].append(event)
                payload = raw
                if browser:
                    result["authenticated_read_performed"] = True
                    result["browser_path"] = browser
                break
            event.update({"status": "error", "error_code": error["code"] if error else "unknown"})
            result["attempts"].append(event)
            last_error = error
            if browser is None:
                if args.no_browser_cookies or not error or error["code"] not in AUTH_CODES:
                    break
            elif args.browser or not error or error["code"] not in AUTH_CODES:
                break

    if payload is None:
        result.update({
            "status": "error",
            "notify_user": True,
            "error": last_error or {
                "code": "enumeration_failed",
                "message": "No playlist enumeration path completed.",
                "repair_action": "Inspect the structured attempts and retry.",
            },
        })
        return result

    urls: list[str] = []
    malformed: list[dict[str, Any]] = []
    seen: set[str] = set()
    entries = payload.get("entries") or []
    if not isinstance(entries, list):
        entries = []
    for index, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            malformed.append({"index": index, "reason": "non_object_entry"})
            continue
        video_id = normalize_video_id(entry)
        if not video_id:
            malformed.append({"index": index, "reason": "invalid_video_id"})
            continue
        if video_id in seen:
            continue
        seen.add(video_id)
        urls.append(f"https://www.youtube.com/watch?v={video_id}")

    if not urls:
        if not entries:
            result["result"] = {
                "title": payload.get("title"),
                "entry_count": 0,
                "valid_count": 0,
                "malformed_entries": [],
                "urls": [],
            }
            return result
        result.update({
            "status": "error",
            "notify_user": True,
            "error": {
                "code": "no_valid_playlist_entries",
                "message": "yt-dlp returned no valid YouTube video entries.",
                "repair_action": "Confirm playlist access and update yt-dlp before retrying.",
            },
            "result": {
                "title": payload.get("title"),
                "entry_count": len(entries),
                "valid_count": 0,
                "malformed_entries": malformed,
                "urls": [],
            },
        })
        return result
    if malformed:
        result["status"] = "partial"
        result["notify_user"] = True
        result["degradation_reasons"].append({
            "code": "malformed_playlist_entries_skipped",
            "count": len(malformed),
            "message": "Valid playlist entries will continue; malformed entries were not submitted.",
        })
    if len(result["attempts"]) > 1:
        result["notify_user"] = True
        result["degradation_reasons"].append({
            "code": "enumeration_route_changed",
            "message": "The initial enumeration path failed and a browser-cookie path was used.",
        })
    result["result"] = {
        "title": payload.get("title"),
        "entry_count": len(entries),
        "valid_count": len(urls),
        "malformed_entries": malformed,
        "urls": urls,
    }
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Enumerate YouTube playlist URLs safely")
    parser.add_argument("--source", required=True)
    parser.add_argument("--mode", choices=("public", "auth"), default="public")
    parser.add_argument("--browser", choices=("safari", "firefox"))
    parser.add_argument("--no-browser-cookies", action="store_true")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.timeout <= 0:
        payload = {
            "schema_version": SCHEMA_VERSION,
            "status": "error",
            "notify_user": True,
            "error": {
                "code": "invalid_timeout",
                "message": "--timeout must be greater than zero.",
                "repair_action": "Use a positive timeout in seconds.",
            },
        }
    else:
        payload = enumerate_playlist(args)
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if payload["status"] in {"ok", "partial"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
