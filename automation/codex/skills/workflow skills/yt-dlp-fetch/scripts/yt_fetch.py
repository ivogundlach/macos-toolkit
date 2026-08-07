#!/usr/bin/env python3
"""Structured, deterministic yt-dlp acquisition for the yt-dlp-fetch skill."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse


SCHEMA_VERSION = 1
AUTH_BROWSERS = ("safari", "firefox")
AUTH_RETRY_CODES = {"authentication_required", "bot_check"}
NEXT_BROWSER_CODES = {
    "authentication_required",
    "bot_check",
    "cookie_tcc_denied",
    "cookie_read_failed",
}
RUN_ROOT = Path(tempfile.gettempdir()) / "yt-dlp-fetch-runs"
RUN_SENTINEL = ".yt-dlp-fetch-run.json"
STALE_SECONDS = 24 * 60 * 60

TCC_PATTERNS = (
    "operation not permitted",
    "permission denied",
    "full disk access",
    "not authorized to send apple events",
)
FIREFOX_LOCK_PATTERNS = (
    "cookies.sqlite",
    "firefox cookie database",
    "could not copy firefox",
    "could not open firefox",
)
COOKIE_PATTERNS = ("cookie", "keychain", "decrypt")
BOT_PATTERNS = (
    "sign in to confirm you're not a bot",
    "sign in to confirm you’re not a bot",
    "confirm you're not a bot",
    "confirm you’re not a bot",
)
AUTH_PATTERNS = (
    "private video",
    "members-only",
    "members only",
    "login required",
    "age-restricted",
    "age restricted",
    "available to members",
)
GEO_PATTERNS = ("not available in your country", "geo-restricted", "geo restricted")
UNAVAILABLE_PATTERNS = ("video unavailable", "has been removed", "does not exist")
NETWORK_PATTERNS = (
    "timed out",
    "temporary failure in name resolution",
    "connection reset",
    "network is unreachable",
)
EXTRACTOR_PATTERNS = ("unable to extract", "signature extraction", "nsig extraction")


class FetchError(RuntimeError):
    def __init__(self, code: str, message: str, repair_action: str | None = None):
        super().__init__(message)
        self.code = code
        self.repair_action = repair_action

    def as_dict(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "message": str(self),
            "repair_action": self.repair_action,
        }


def _contains(text: str, patterns: tuple[str, ...]) -> bool:
    return any(pattern in text for pattern in patterns)


def sanitize_diagnostic(value: str, limit: int = 1200) -> str:
    """Keep useful diagnostics while stripping common cookie/token renderings."""
    text = value.replace("\r", "")
    text = re.sub(r"(?i)(auth_token|ct0|cookie|authorization)\s*[:=]\s*[^\s;,]+", r"\1=[REDACTED]", text)
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", text)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return " | ".join(lines[-8:])[:limit]


def classify_failure(stderr: str, browser: str | None = None) -> FetchError:
    text = stderr.lower()
    detail = sanitize_diagnostic(stderr) or "yt-dlp failed without diagnostic output"
    if browser == "safari" and _contains(text, TCC_PATTERNS):
        return FetchError(
            "cookie_tcc_denied",
            detail,
            "Grant Full Disk Access to the invoking Codex/terminal process in System Settings > Privacy & Security, then retry; Firefox is attempted automatically first.",
        )
    if browser == "firefox" and _contains(text, FIREFOX_LOCK_PATTERNS):
        return FetchError(
            "cookie_read_failed",
            detail,
            "Close Firefox so yt-dlp can copy cookies.sqlite, or update yt-dlp, then retry.",
        )
    if browser and _contains(text, COOKIE_PATTERNS):
        return FetchError(
            "cookie_read_failed",
            detail,
            f"Confirm {browser.title()} is signed in, close it if the cookie database is locked, update yt-dlp, then retry.",
        )
    if _contains(text, BOT_PATTERNS):
        repair = (
            f"The bot check persisted with {browser.title()} cookies. Update yt-dlp and avoid repeated authenticated retries because the signed-in account was exposed to the challenge."
            if browser
            else "Retry once with local browser cookies. If the bot check persists, update yt-dlp and avoid repeated authenticated retries because they expose the signed-in account to the challenge."
        )
        return FetchError("bot_check", detail, repair)
    if _contains(text, AUTH_PATTERNS) or "sign in" in text:
        repair = (
            f"Confirm the {browser.title()} session can open the media, then retry."
            if browser
            else "Allow the automatic Safari/Firefox cookie retry or force it with --auth."
        )
        return FetchError("authentication_required", detail, repair)
    if _contains(text, GEO_PATTERNS):
        return FetchError("geo_restricted", detail, "Use an authorized network location where the media is available, then retry.")
    if _contains(text, UNAVAILABLE_PATTERNS):
        return FetchError("media_unavailable", detail, "Confirm the URL and that the media still exists, then retry.")
    if _contains(text, NETWORK_PATTERNS):
        return FetchError("network_failed", detail, "Check connectivity and retry the same request once.")
    if _contains(text, EXTRACTOR_PATTERNS):
        return FetchError("extractor_failed", detail, "Update yt-dlp with brew upgrade yt-dlp, then retry.")
    return FetchError("acquisition_failed", detail, "Update yt-dlp with brew upgrade yt-dlp, then retry.")


def _is_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def resolve_ytdlp() -> str | None:
    override = os.environ.get("YTDLP")
    if override and Path(override).expanduser().is_file():
        return str(Path(override).expanduser())
    if Path("/opt/homebrew/bin/yt-dlp").is_file():
        return "/opt/homebrew/bin/yt-dlp"
    return shutil.which("yt-dlp")


def is_stale_version(version: str) -> bool:
    match = re.match(r"(\d{4})", version.strip())
    return bool(match and int(match.group(1)) < 2025)


def preflight() -> dict[str, Any]:
    binary = resolve_ytdlp()
    version = "unknown"
    if binary:
        proc = subprocess.run([binary, "--version"], capture_output=True, text=True)
        if proc.returncode == 0:
            version = proc.stdout.strip()
    return {
        "can_proceed": bool(binary),
        "python": sys.executable,
        "python_version": ".".join(str(part) for part in sys.version_info[:3]),
        "yt_dlp": binary,
        "yt_dlp_version": version,
        "yt_dlp_stale": is_stale_version(version),
        "ffmpeg": shutil.which("ffmpeg"),
        "repair_action": None if binary else "Install yt-dlp with brew install yt-dlp, then retry.",
    }


def _ensure_run_root() -> None:
    RUN_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(RUN_ROOT, 0o700)


def sweep_stale_runs(now: float | None = None) -> list[str]:
    _ensure_run_root()
    removed: list[str] = []
    cutoff = (now or time.time()) - STALE_SECONDS
    root_real = RUN_ROOT.resolve()
    for child in RUN_ROOT.iterdir():
        if not child.is_dir() or child.parent.resolve() != root_real:
            continue
        sentinel = child / RUN_SENTINEL
        try:
            data = json.loads(sentinel.read_text(encoding="utf-8"))
            created = float(data["created_at"])
            run_id = str(data["run_id"])
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            continue
        if created < cutoff and child.name.endswith(run_id):
            shutil.rmtree(child)
            removed.append(str(child))
    return removed


def create_run() -> tuple[Path, str, list[str]]:
    stale = sweep_stale_runs()
    run_id = uuid.uuid4().hex
    run_dir = Path(tempfile.mkdtemp(prefix="run-", suffix="-" + run_id, dir=str(RUN_ROOT)))
    os.chmod(run_dir, 0o700)
    sentinel = run_dir / RUN_SENTINEL
    sentinel.write_text(json.dumps({"run_id": run_id, "created_at": time.time()}), encoding="utf-8")
    os.chmod(sentinel, 0o600)
    return run_dir, run_id, stale


def _subprocess_env(run_dir: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["TMPDIR"] = str(run_dir)
    return env


def run_ytdlp(binary: str, args: list[str], run_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [binary, *args],
        capture_output=True,
        text=True,
        env=_subprocess_env(run_dir),
    )


def _cookie_args(browser: str | None) -> list[str]:
    return ["--cookies-from-browser", browser] if browser else []


def _record_attempt(
    manifest: dict[str, Any], method: str, status: str, browser: str | None = None, error: FetchError | None = None
) -> None:
    attempt: dict[str, Any] = {"method": method, "status": status}
    if browser:
        attempt["browser"] = browser
    if error:
        attempt["error_code"] = error.code
        attempt["diagnostic"] = str(error)
    manifest["attempts"].append(attempt)


def with_cookie_policy(
    manifest: dict[str, Any],
    method: str,
    call: Callable[[str | None], Any],
    *,
    force_auth: bool,
    no_browser_cookies: bool,
) -> tuple[Any, str | None]:
    trigger: str | None = "forced_auth" if force_auth else None
    if not force_auth:
        try:
            result = call(None)
            _record_attempt(manifest, method + "_public", "ok")
            return result, None
        except FetchError as exc:
            _record_attempt(manifest, method + "_public", "failed", error=exc)
            if exc.code not in AUTH_RETRY_CODES or no_browser_cookies:
                if no_browser_cookies and exc.code in AUTH_RETRY_CODES:
                    exc.repair_action = "Remove --no-browser-cookies to permit automatic Safari/Firefox authentication, then retry."
                raise
            trigger = exc.code

    last_error: FetchError | None = None
    failed_browsers: list[str] = []
    for browser in AUTH_BROWSERS:
        event: dict[str, Any] = {
            "browser": browser,
            "status": "attempted",
            "reason": trigger,
            "cookie_values_persisted": False,
        }
        manifest["auth_events"].append(event)
        try:
            result = call(browser)
        except FetchError as exc:
            last_error = exc
            failed_browsers.append(browser)
            event.update({"status": "failed", "error_code": exc.code})
            _record_attempt(manifest, method + "_authenticated", "failed", browser, exc)
            if exc.code in NEXT_BROWSER_CODES:
                continue
            raise
        event["status"] = "ok"
        _record_attempt(manifest, method + "_authenticated", "ok", browser)
        if failed_browsers:
            manifest["warnings"].append(
                f"Cookie authentication changed browser after {', '.join(failed_browsers)} failed; {browser} succeeded."
            )
        if trigger == "bot_check":
            manifest["warnings"].append(
                f"A public bot check triggered an authenticated retry through {browser}; the signed-in account was exposed to that challenge."
            )
        return result, browser
    if last_error:
        raise last_error
    raise FetchError("authentication_failed", "No browser-cookie authentication path ran")


def _parse_json(stdout: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise FetchError("invalid_json", f"yt-dlp returned invalid {label} JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise FetchError("invalid_json", f"yt-dlp returned non-object {label} JSON")
    return value


def metadata(binary: str, source: str, run_dir: Path, browser: str | None, *, playlist: bool = False) -> dict[str, Any]:
    args = [
        *_cookie_args(browser),
        "--dump-single-json",
        "--skip-download",
        "--yes-playlist" if playlist else "--no-playlist",
        "--no-warnings",
        "--",
        source,
    ]
    proc = run_ytdlp(binary, args, run_dir)
    if proc.returncode != 0:
        raise classify_failure(proc.stderr, browser)
    return _parse_json(proc.stdout, "metadata")


def normalize_info(raw: dict[str, Any], source: str, include_description: bool) -> dict[str, Any]:
    result = {
        "title": raw.get("title"),
        "channel": raw.get("channel") or raw.get("uploader"),
        "channel_url": raw.get("channel_url") or raw.get("uploader_url"),
        "upload_date": raw.get("upload_date"),
        "duration_seconds": raw.get("duration"),
        "duration": raw.get("duration_string"),
        "webpage_url": raw.get("webpage_url") or source,
        "extractor": raw.get("extractor_key") or raw.get("extractor"),
        "availability": raw.get("availability"),
    }
    if include_description:
        result["description"] = raw.get("description")
    return result


def choose_caption(raw: dict[str, Any]) -> tuple[str | None, str | None]:
    manual = {key: value for key, value in (raw.get("subtitles") or {}).items() if key != "live_chat" and value}
    automatic = {
        key: value for key, value in (raw.get("automatic_captions") or {}).items() if key != "live_chat" and value
    }
    original = str(raw.get("language") or "").strip().lower()

    def english(pool: dict[str, Any]) -> str | None:
        priorities = ("en", "en-orig", "en-us", "en-gb")
        lowered = {key.lower(): key for key in pool}
        for candidate in priorities:
            if candidate in lowered:
                return lowered[candidate]
        return next((key for key in sorted(pool) if key.lower().startswith("en-")), None)

    def original_track(pool: dict[str, Any]) -> str | None:
        if not original:
            return None
        return next(
            (key for key in sorted(pool) if key.lower() == original or key.lower().startswith(original + "-")),
            None,
        )

    selected = english(manual)
    if selected:
        return selected, "manual"
    selected = english(automatic)
    if selected:
        return selected, "automatic"
    selected = original_track(manual)
    if selected:
        return selected, "manual"
    if manual:
        return sorted(manual)[0], "manual"
    selected = original_track(automatic)
    if selected:
        return selected, "automatic"
    if automatic:
        return sorted(automatic)[0], "automatic"
    return None, None


TIMESTAMP_RE = re.compile(
    r"(?:(?P<h>\d+):)?(?P<m>\d{2}):(?P<s>\d{2})[.,](?P<ms>\d{3})\s+-->\s+"
    r"(?:(?P<eh>\d+):)?(?P<em>\d{2}):(?P<es>\d{2})[.,](?P<ems>\d{3})"
)


def _seconds(h: str | None, m: str, s: str, ms: str) -> float:
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000


def parse_vtt(path: Path) -> list[dict[str, Any]]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    segments: list[dict[str, Any]] = []
    index = 0
    while index < len(lines):
        match = TIMESTAMP_RE.search(lines[index])
        if not match:
            index += 1
            continue
        start = _seconds(match.group("h"), match.group("m"), match.group("s"), match.group("ms"))
        end = _seconds(match.group("eh"), match.group("em"), match.group("es"), match.group("ems"))
        index += 1
        text_lines: list[str] = []
        while index < len(lines) and lines[index].strip():
            cleaned = re.sub(r"<[^>]+>", "", lines[index])
            cleaned = re.sub(r"\s+", " ", cleaned).strip()
            if cleaned:
                text_lines.append(cleaned)
            index += 1
        text = " ".join(text_lines).strip()
        if text and (not segments or text != segments[-1]["text"]):
            segments.append({"start": start, "end": end, "text": text})
        index += 1
    return segments


def format_timestamp(seconds: float) -> str:
    whole = int(seconds)
    hours, remainder = divmod(whole, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def transcript_text(segments: list[dict[str, Any]]) -> str:
    return " ".join(segment["text"] for segment in segments).strip()


def _safe_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-._")
    return (slug[:90] or "video")


def collision_safe_path(directory: Path, base: str, suffix: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    candidate = directory / f"{base}{suffix}"
    counter = 2
    while candidate.exists():
        candidate = directory / f"{base}-{counter}{suffix}"
        counter += 1
    return candidate


def operation_info(
    binary: str, source: str, run_dir: Path, browser: str | None, args: argparse.Namespace
) -> dict[str, Any]:
    return normalize_info(metadata(binary, source, run_dir, browser), source, args.desc)


def operation_transcript(
    binary: str, source: str, run_dir: Path, browser: str | None, args: argparse.Namespace
) -> dict[str, Any]:
    raw = metadata(binary, source, run_dir, browser)
    language, kind = choose_caption(raw)
    if not language or not kind:
        raise FetchError(
            "no_captions",
            "The media metadata contains no usable caption track.",
            "Use the Watch skill for visual evidence or configure Groq in Watch later for captionless speech.",
        )
    caption_dir = run_dir / "captions"
    caption_dir.mkdir(mode=0o700)
    command = [
        *_cookie_args(browser),
        "--skip-download",
        "--write-subs" if kind == "manual" else "--write-auto-subs",
        "--sub-langs",
        language,
        "--sub-format",
        "vtt/best",
        "--convert-subs",
        "vtt",
        "--no-playlist",
        "--no-warnings",
        "-o",
        str(caption_dir / "track.%(ext)s"),
        "--",
        source,
    ]
    proc = run_ytdlp(binary, command, run_dir)
    if proc.returncode != 0:
        raise classify_failure(proc.stderr, browser)
    candidates = sorted(caption_dir.glob("*.vtt"))
    if not candidates:
        raise FetchError(
            "caption_download_failed",
            f"yt-dlp advertised {kind} captions in {language!r} but produced no VTT file.",
            "Update yt-dlp and retry the same transcript request.",
        )
    segments = parse_vtt(candidates[0])
    if not segments:
        raise FetchError(
            "caption_parse_failed",
            "The acquired VTT contained no readable caption segments.",
            "Update yt-dlp and retry; use Watch if the platform caption track remains malformed.",
        )
    full_text = transcript_text(segments)
    saved_path: str | None = None
    if args.save is not None:
        if args.save == "auto":
            title = str(raw.get("title") or "video")
            target = collision_safe_path(Path.home() / "Downloads", _safe_slug(title) + "-transcript", ".txt")
        else:
            target = Path(args.save).expanduser().resolve()
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.parent == (Path.home() / "Files").resolve():
                raise FetchError(
                    "unsafe_output_path",
                    "Refusing to save a loose transcript at the visible ~/Files root; use Downloads or a named subfolder.",
                )
        target.write_text(full_text + "\n", encoding="utf-8")
        saved_path = str(target)
    inline = full_text
    truncated = False
    output_segments = segments
    if args.max_inline_chars is not None and len(inline) > args.max_inline_chars:
        inline = inline[: args.max_inline_chars].rstrip() + "…"
        truncated = True
        output_segments = []
        used = 0
        for segment in segments:
            cost = len(str(segment["text"])) + 1
            if output_segments and used + cost > args.max_inline_chars:
                break
            output_segments.append(segment)
            used += cost
    return {
        "title": raw.get("title"),
        "webpage_url": raw.get("webpage_url") or source,
        "caption_language": language,
        "caption_kind": kind,
        "segment_count": len(segments),
        "segments": [
            {**segment, "timestamp": format_timestamp(float(segment["start"]))}
            for segment in output_segments
        ],
        "segments_truncated": len(output_segments) < len(segments),
        "text": inline,
        "text_truncated": truncated,
        "full_text_characters": len(full_text),
        "saved_path": saved_path,
        "video_downloaded": False,
        "audio_downloaded": False,
    }


def operation_list(
    binary: str, source: str, run_dir: Path, browser: str | None, args: argparse.Namespace
) -> dict[str, Any]:
    command = [
        *_cookie_args(browser),
        "--flat-playlist",
        "--dump-single-json",
        "--no-warnings",
    ]
    if args.limit is not None:
        command.extend(["--playlist-end", str(args.limit)])
    command.extend(["--", source])
    proc = run_ytdlp(binary, command, run_dir)
    if proc.returncode != 0:
        raise classify_failure(proc.stderr, browser)
    raw = _parse_json(proc.stdout, "playlist")
    entries = []
    for offset, entry in enumerate(raw.get("entries") or [], start=1):
        if not isinstance(entry, dict):
            continue
        entries.append({
            "index": entry.get("playlist_index") or offset,
            "title": entry.get("title"),
            "url": entry.get("webpage_url") or entry.get("url"),
            "id": entry.get("id"),
            "availability": entry.get("availability"),
        })
    return {
        "title": raw.get("title"),
        "webpage_url": raw.get("webpage_url") or source,
        "entry_count": len(entries),
        "entries": entries,
    }


def operation_get(
    binary: str, source: str, run_dir: Path, browser: str | None, args: argparse.Namespace
) -> dict[str, Any]:
    out_dir = Path(args.outdir).expanduser().resolve() if args.outdir else Path.home() / "Files" / "YouTube"
    out_dir.mkdir(parents=True, exist_ok=True)
    files_root = (Path.home() / "Files").resolve()
    if out_dir == files_root:
        raise FetchError("unsafe_output_path", f"Refusing to download directly into {files_root}; use a media subfolder.")
    if args.playlist:
        template = out_dir / "%(playlist_title)s" / "%(playlist_index)03d - %(title)s" / "%(title)s (%(height)sp_%(fps)sfps).%(ext)s"
    else:
        template = out_dir / "%(title)s" / "%(title)s (%(height)sp_%(fps)sfps).%(ext)s"
    command = [
        *_cookie_args(browser),
        "--yes-playlist" if args.playlist else "--no-playlist",
        "-f",
        "bv*+ba/b",
        "--merge-output-format",
        "mp4",
        "--quiet",
        "--no-warnings",
        "--print",
        "after_move:filepath",
        "-o",
        str(template),
    ]
    if args.playlist and args.limit is not None:
        command.extend(["--playlist-end", str(args.limit)])
    command.extend(["--", source])
    proc = run_ytdlp(binary, command, run_dir)
    paths = [Path(line.strip()).expanduser().resolve() for line in proc.stdout.splitlines() if line.strip()]
    existing = [path for path in paths if path.is_file()]
    if proc.returncode != 0 and not existing:
        raise classify_failure(proc.stderr, browser)
    if proc.returncode == 0 and not existing:
        raise FetchError(
            "output_verification_failed",
            "yt-dlp returned success but no printed final filepath exists.",
            "Inspect the destination and update yt-dlp before retrying.",
        )
    partial = proc.returncode != 0 or len(existing) != len(paths)
    return {
        "outdir": str(out_dir),
        "playlist": bool(args.playlist),
        "requested_limit": args.limit,
        "files": [str(path) for path in existing],
        "file_count": len(existing),
        "partial": partial,
        "exit_code": proc.returncode,
        "diagnostic": sanitize_diagnostic(proc.stderr) if partial else None,
    }


OPERATIONS: dict[str, Callable[..., dict[str, Any]]] = {
    "info": operation_info,
    "transcript": operation_transcript,
    "list": operation_list,
    "get": operation_get,
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Structured yt-dlp acquisition wrapper")
    parser.add_argument("operation", choices=sorted(OPERATIONS))
    parser.add_argument("source")
    parser.add_argument("--auth", action="store_true", help="Force browser-cookie authentication")
    parser.add_argument("--no-browser-cookies", action="store_true", help="Disable automatic browser-cookie retry")
    parser.add_argument("--desc", action="store_true", help="Include description in info output")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--save", nargs="?", const="auto", help="Save transcript; omit path for Downloads")
    parser.add_argument("--max-inline-chars", type=int)
    parser.add_argument("--outdir")
    parser.add_argument("--playlist", action="store_true", help="Explicitly download a playlist")
    return parser


def validate_args(args: argparse.Namespace) -> FetchError | None:
    if not _is_url(args.source):
        return FetchError("invalid_url", "Source must be an http(s) video, playlist, or channel URL.")
    if args.auth and args.no_browser_cookies:
        return FetchError("conflicting_auth_options", "--auth and --no-browser-cookies are contradictory; use only one.")
    if args.limit is not None and args.limit <= 0:
        return FetchError("invalid_limit", "--limit must be greater than zero.")
    if args.max_inline_chars is not None and args.max_inline_chars <= 0:
        return FetchError("invalid_inline_limit", "--max-inline-chars must be greater than zero.")
    if args.desc and args.operation != "info":
        return FetchError("invalid_option", "--desc applies only to info.")
    if args.save is not None and args.operation != "transcript":
        return FetchError("invalid_option", "--save applies only to transcript.")
    if args.max_inline_chars is not None and args.operation != "transcript":
        return FetchError("invalid_option", "--max-inline-chars applies only to transcript.")
    if args.outdir and args.operation != "get":
        return FetchError("invalid_option", "--outdir applies only to get.")
    if args.playlist and args.operation != "get":
        return FetchError("invalid_option", "--playlist applies only to get.")
    if args.limit is not None and args.operation not in {"list", "get"}:
        return FetchError("invalid_option", "--limit applies only to list or playlist get.")
    if args.operation == "get" and args.limit is not None and not args.playlist:
        return FetchError("invalid_option", "--limit on get requires explicit --playlist.")
    return None


def run(args: argparse.Namespace) -> dict[str, Any]:
    status = preflight()
    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "notify_user": False,
        "operation": args.operation,
        "source": args.source,
        "preflight": status,
        "attempts": [],
        "auth_events": [],
        "warnings": [],
        "degradations": [],
        "result": None,
    }
    invalid = validate_args(args)
    if invalid:
        manifest.update({"status": "error", "notify_user": True, "error": invalid.as_dict()})
        return manifest
    if not status["can_proceed"]:
        error = FetchError("preflight_failed", "yt-dlp is unavailable.", status["repair_action"])
        manifest.update({"status": "error", "notify_user": True, "error": error.as_dict()})
        return manifest
    if sys.version_info < (3, 9):
        error = FetchError("python_too_old", "yt-dlp-fetch requires Python 3.9+.", "Set YT_FETCH_PYTHON to Python 3.9+ and retry.")
        manifest.update({"status": "error", "notify_user": True, "error": error.as_dict()})
        return manifest

    run_dir, run_id, stale = create_run()
    manifest["run"] = {"id": run_id, "stale_runs_removed": len(stale), "temp_mode": oct(stat.S_IMODE(run_dir.stat().st_mode))}
    try:
        operation = OPERATIONS[args.operation]
        result, browser = with_cookie_policy(
            manifest,
            args.operation,
            lambda selected_browser: operation(
                str(status["yt_dlp"]), args.source, run_dir, selected_browser, args
            ),
            force_auth=args.auth,
            no_browser_cookies=args.no_browser_cookies,
        )
        if browser:
            result["authenticated_with"] = browser
        manifest["result"] = result
        if status["yt_dlp_stale"]:
            manifest["warnings"].append(
                f"yt-dlp {status['yt_dlp_version']} appears stale; update with brew upgrade yt-dlp."
            )
        if args.operation == "get" and result.get("partial"):
            manifest["status"] = "partial"
            manifest["degradations"].append({
                "code": "partial_download",
                "message": "Some requested media files were produced before yt-dlp failed.",
                "repair_action": "Review the verified file list and retry the missing item(s); existing files are preserved.",
            })
        manifest["notify_user"] = bool(
            manifest["status"] != "ok" or manifest["warnings"] or manifest["degradations"]
        )
    except FetchError as exc:
        manifest.update({"status": "error", "notify_user": True, "error": exc.as_dict()})
    except Exception as exc:
        error = FetchError(
            "unexpected_failure",
            f"{type(exc).__name__}: {sanitize_diagnostic(str(exc))}",
            "Run scripts/selftest.py, inspect the structured attempts, and retry only after the failing path is understood.",
        )
        manifest.update({"status": "error", "notify_user": True, "error": error.as_dict()})
    finally:
        shutil.rmtree(run_dir, ignore_errors=True)
    manifest["run"]["cleaned"] = not run_dir.exists()
    return manifest


def main() -> int:
    args = build_parser().parse_args()
    manifest = run(args)
    print(json.dumps(manifest, indent=2, ensure_ascii=False))
    return 0 if manifest["status"] in {"ok", "partial"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
