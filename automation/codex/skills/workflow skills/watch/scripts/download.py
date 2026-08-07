#!/usr/bin/env python3
"""Acquire video metadata, captions, and media through a structured yt-dlp path."""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from config import resolve_binary  # noqa: E402


VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}
MEDIA_EXTS = (*VIDEO_EXTS, ".m4a", ".mp3", ".opus")
TCC_PATTERNS = (
    "operation not permitted",
    "permission denied",
    "full disk access",
    "not authorized to send apple events",
)
COOKIE_PATTERNS = ("cookie", "keychain", "decrypt", "safari")
FIREFOX_COOKIE_PATTERNS = (
    "firefox cookie database",
    "cookies.sqlite",
    "could not copy firefox",
    "could not open firefox",
)
BOT_CHECK_PATTERNS = (
    "sign in to confirm you're not a bot",
    "sign in to confirm you’re not a bot",
    "confirm you're not a bot",
    "confirm you’re not a bot",
)
AUTH_REQUIRED_PATTERNS = (
    "login required",
    "private video",
    "members-only",
    "members only",
    "age-restricted",
    "age restricted",
    "this video is available to members",
)
GEO_PATTERNS = ("not available in your country", "geo-restricted", "geo restricted")
UNAVAILABLE_PATTERNS = ("video unavailable", "has been removed", "does not exist")
NETWORK_PATTERNS = ("timed out", "temporary failure in name resolution", "connection reset")
EXTRACTOR_PATTERNS = ("unable to extract", "signature extraction", "nsig extraction")


class AcquisitionError(RuntimeError):
    def __init__(self, code: str, message: str, repair_action: str | None = None):
        super().__init__(message)
        self.code = code
        self.repair_action = repair_action

    def as_dict(self) -> dict[str, object]:
        return {
            "code": self.code,
            "message": str(self),
            "repair_action": self.repair_action,
        }


def is_url(source: str) -> bool:
    if source.startswith("-"):
        return False
    parsed = urlparse(source)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def _yt_dlp() -> str:
    binary = resolve_binary("yt-dlp")
    if not binary:
        raise AcquisitionError(
            "missing_dependency", "yt-dlp is not installed", "Install after approval: brew install yt-dlp"
        )
    return binary


def ytdlp_version(binary: str | None = None) -> dict[str, object]:
    binary = binary or _yt_dlp()
    result = subprocess.run([binary, "--version"], capture_output=True, text=True)
    version = result.stdout.strip() if result.returncode == 0 else "unknown"
    stale = is_stale_ytdlp_version(version)
    return {"binary": binary, "version": version, "stale": stale}


def is_stale_ytdlp_version(version: str) -> bool:
    match = re.match(r"(\d{4})", version.strip())
    return bool(match and int(match.group(1)) < 2025)


def _auth_args(auth: bool, browser: str = "safari") -> list[str]:
    return ["--cookies-from-browser", browser] if auth else []


def _compact_error(stderr: str, limit: int = 700) -> str:
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    return " | ".join(lines[-5:])[:limit]


def _classify_failure(stderr: str, auth: bool, browser: str = "safari") -> AcquisitionError:
    text = stderr.lower()
    detail = _compact_error(stderr) or "yt-dlp failed without diagnostic output"
    if auth and browser == "safari" and any(pattern in text for pattern in TCC_PATTERNS):
        return AcquisitionError(
            "auth_tcc_denied",
            detail,
            "Grant Full Disk Access to the invoking Codex/terminal process in System Settings > Privacy & Security, then retry; Firefox is attempted automatically first.",
        )
    if auth and browser == "firefox" and any(pattern in text for pattern in FIREFOX_COOKIE_PATTERNS):
        return AcquisitionError(
            "auth_cookie_extraction_failed",
            detail,
            "Close Firefox so its cookie database can be copied, or update yt-dlp, then retry.",
        )
    if auth and any(pattern in text for pattern in COOKIE_PATTERNS):
        return AcquisitionError(
            "auth_cookie_extraction_failed",
            detail,
            f"Confirm {browser.title()} is signed in to the site, close it if its cookie database is locked, update yt-dlp, then retry.",
        )
    if any(pattern in text for pattern in BOT_CHECK_PATTERNS):
        repair = (
            "Watch will retry once through Safari and Firefox cookies. If the bot check persists, update yt-dlp and avoid repeated authenticated retries because they expose the signed-in account to the challenge."
            if not auth
            else f"The bot check persisted with {browser.title()} cookies. Update yt-dlp and avoid repeated authenticated retries because the signed-in account has been exposed to the challenge."
        )
        return AcquisitionError("bot_check", detail, repair)
    if any(pattern in text for pattern in AUTH_REQUIRED_PATTERNS) or "sign in" in text:
        repair = (
            "Retry with local browser cookies; Watch does this automatically unless --no-browser-cookies is set."
            if not auth
            else f"Confirm the {browser.title()} session can open the video, then retry."
        )
        return AcquisitionError("authentication_required", detail, repair)
    if any(pattern in text for pattern in GEO_PATTERNS):
        return AcquisitionError("geo_restricted", detail, "Use an authorized network location where the media is available, then retry.")
    if any(pattern in text for pattern in UNAVAILABLE_PATTERNS):
        return AcquisitionError("media_unavailable", detail, "Confirm the URL and that the media still exists, then retry.")
    if any(pattern in text for pattern in NETWORK_PATTERNS):
        return AcquisitionError("network_failed", detail, "Check connectivity and retry the same request once.")
    if any(pattern in text for pattern in EXTRACTOR_PATTERNS):
        return AcquisitionError("extractor_failed", detail, "Update yt-dlp with brew upgrade yt-dlp, then retry.")
    return AcquisitionError(
        "acquisition_failed",
        detail,
        "Update yt-dlp and retry. If the video is gated, allow the automatic browser-cookie path.",
    )


def resolve_local(path: str) -> dict[str, object]:
    candidate = Path(path).expanduser().resolve()
    if not candidate.exists() or not candidate.is_file():
        raise AcquisitionError("file_not_found", f"Local video not found: {candidate}")
    warning = None
    if candidate.suffix.lower() not in VIDEO_EXTS:
        warning = f"Unrecognized video extension {candidate.suffix}; attempting ffprobe anyway."
    sidecar = candidate.with_suffix(".vtt")
    return {
        "video_path": str(candidate),
        "subtitle_path": str(sidecar) if sidecar.exists() else None,
        "caption_language": None,
        "caption_kind": "sidecar" if sidecar.exists() else None,
        "info": {"title": candidate.name, "url": str(candidate)},
        "downloaded": False,
        "attempts": [{"method": "local_file", "status": "ok"}],
        "warnings": [warning] if warning else [],
    }


def choose_subtitle_track(info: dict) -> tuple[str | None, str | None]:
    """Prefer manual original-language captions, then manual English, then auto."""
    manual = {k: v for k, v in (info.get("subtitles") or {}).items() if k != "live_chat" and v}
    automatic = {
        k: v for k, v in (info.get("automatic_captions") or {}).items() if k != "live_chat" and v
    }
    original = str(info.get("language") or "").strip()

    def select(pool: dict) -> str | None:
        if original:
            exact = next((key for key in pool if key == original or key.startswith(original + "-")), None)
            if exact:
                return exact
        english = next((key for key in pool if key == "en" or key.startswith("en-")), None)
        if english:
            return english
        return sorted(pool)[0] if pool else None

    language = select(manual)
    if language:
        return language, "manual"
    language = select(automatic)
    return (language, "automatic") if language else (None, None)


def _metadata(url: str, auth: bool, browser: str = "safari") -> tuple[dict, dict[str, object]]:
    binary = _yt_dlp()
    cmd = [
        binary,
        *_auth_args(auth, browser),
        "--dump-single-json",
        "--skip-download",
        "--no-playlist",
        "--no-warnings",
        "--",
        url,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    attempt = {
        "method": "yt_dlp_metadata_auth" if auth else "yt_dlp_metadata_public",
        "status": "ok" if result.returncode == 0 else "failed",
        "exit_code": result.returncode,
    }
    if auth:
        attempt["browser"] = browser
    if result.returncode != 0:
        raise _classify_failure(result.stderr, auth, browser)
    try:
        return json.loads(result.stdout), attempt
    except json.JSONDecodeError as exc:
        raise AcquisitionError("metadata_invalid", f"yt-dlp returned invalid metadata JSON: {exc}") from exc


def _info(raw: dict, url: str) -> dict[str, object]:
    return {
        "title": raw.get("title"),
        "uploader": raw.get("uploader") or raw.get("channel"),
        "duration": raw.get("duration"),
        "language": raw.get("language"),
        "url": raw.get("webpage_url") or url,
    }


def _pick_subtitle(out_dir: Path) -> Path | None:
    candidates = sorted(out_dir.glob("video*.vtt"))
    return candidates[0] if candidates else None


def _pick_media(out_dir: Path) -> Path | None:
    for ext in MEDIA_EXTS:
        candidate = next(iter(sorted(out_dir.glob(f"video*{ext}"))), None)
        if candidate:
            return candidate
    return None


def fetch_captions(
    url: str, out_dir: Path, auth: bool = False, browser: str = "safari"
) -> dict[str, object]:
    raw, metadata_attempt = _metadata(url, auth, browser)
    language, kind = choose_subtitle_track(raw)
    attempts = [metadata_attempt]
    warnings: list[str] = []
    subtitle: Path | None = None
    if language:
        out_dir.mkdir(parents=True, exist_ok=True)
        binary = _yt_dlp()
        cmd = [
            binary,
            *_auth_args(auth, browser),
            "--skip-download",
            "--write-subs" if kind == "manual" else "--write-auto-subs",
            "--sub-langs", language,
            "--sub-format", "vtt/best",
            "--convert-subs", "vtt",
            "--no-playlist",
            "--no-warnings",
            "-o", str(out_dir / "video.%(ext)s"),
            "--",
            url,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        subtitle = _pick_subtitle(out_dir)
        attempts.append({
            "method": f"yt_dlp_{kind}_captions",
            "status": "ok" if subtitle else "failed",
            "exit_code": result.returncode,
            "language": language,
            **({"browser": browser} if auth else {}),
        })
        if not subtitle:
            if result.returncode != 0:
                warnings.append(_compact_error(result.stderr))
            warnings.append(f"Advertised {kind} caption track {language!r} was not acquired.")
    else:
        attempts.append({"method": "caption_discovery", "status": "unavailable"})
    version = ytdlp_version()
    if version["stale"]:
        warnings.append(f"yt-dlp {version['version']} appears stale; update with brew upgrade yt-dlp.")
    return {
        "video_path": None,
        "subtitle_path": str(subtitle) if subtitle else None,
        "caption_language": language if subtitle else None,
        "caption_kind": kind if subtitle else None,
        "info": _info(raw, url),
        "downloaded": False,
        "attempts": attempts,
        "warnings": warnings,
        "yt_dlp": version,
    }


def download_url(
    url: str,
    out_dir: Path,
    audio_only: bool = False,
    auth: bool = False,
    browser: str = "safari",
) -> dict[str, object]:
    out_dir.mkdir(parents=True, exist_ok=True)
    binary = _yt_dlp()
    fmt = "ba/bestaudio" if audio_only else "bv*[height<=720]+ba/b[height<=720]/bv+ba/b"
    cmd = [
        binary,
        *_auth_args(auth, browser),
        "-N", "8",
        "-f", fmt,
        "--merge-output-format", "mp4",
        "--write-info-json",
        "--no-playlist",
        "--no-warnings",
        "-o", str(out_dir / "video.%(ext)s"),
        "--",
        url,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    media = _pick_media(out_dir)
    if not media:
        raise _classify_failure(result.stderr, auth, browser)
    warnings = []
    if result.returncode != 0:
        warnings.append(
            "yt-dlp returned non-zero after producing media: " + _compact_error(result.stderr)
        )
    info_path = out_dir / "video.info.json"
    raw: dict = {}
    if info_path.exists():
        try:
            raw = json.loads(info_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            warnings.append(f"Downloaded metadata could not be parsed: {exc}")
    return {
        "video_path": str(media),
        "subtitle_path": None,
        "caption_language": None,
        "caption_kind": None,
        "info": _info(raw, url),
        "downloaded": True,
        "attempts": [{
            "method": "yt_dlp_media_auth" if auth else "yt_dlp_media_public",
            "status": "ok_with_warning" if warnings else "ok",
            "exit_code": result.returncode,
            "audio_only": audio_only,
            **({"browser": browser} if auth else {}),
        }],
        "warnings": warnings,
        "yt_dlp": ytdlp_version(binary),
    }


def download(
    source: str,
    out_dir: Path,
    audio_only: bool = False,
    auth: bool = False,
    browser: str = "safari",
) -> dict[str, object]:
    if is_url(source):
        return download_url(source, out_dir, audio_only=audio_only, auth=auth, browser=browser)
    return resolve_local(source)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: download.py <url-or-path> <out-dir> [--auth]", file=sys.stderr)
        raise SystemExit(2)
    try:
        result = download(sys.argv[1], Path(sys.argv[2]), auth="--auth" in sys.argv[3:])
        print(json.dumps(result, indent=2))
    except AcquisitionError as exc:
        print(json.dumps({"status": "error", "error": exc.as_dict()}, indent=2))
        raise SystemExit(1)
