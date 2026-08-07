#!/usr/bin/env python3
"""Offline deterministic self-test for yt-dlp-fetch."""
from __future__ import annotations

import json
import os
import shlex
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import yt_fetch  # noqa: E402


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def parse_args(*values: str):
    return yt_fetch.build_parser().parse_args(values)


def make_fake_ytdlp(path: Path) -> None:
    path.write_text(
        r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
log = os.environ.get("FAKE_YTDLP_LOG")
if log:
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(args) + "\n")
if args == ["--version"]:
    print("2026.06.09")
    raise SystemExit(0)

source = args[-1]
browser = None
if "--cookies-from-browser" in args:
    browser = args[args.index("--cookies-from-browser") + 1]

def fail(message, code=1):
    print("ERROR: " + message, file=sys.stderr)
    raise SystemExit(code)

if "crash-temp" in source:
    Path(os.environ["TMPDIR"]).joinpath("cookies.txt").write_text("auth_token=never-survive")
    fail("connection reset")
if "seeded-secret" in source:
    secret = os.environ["SEEDED_COOKIE_SECRET"]
    Path(os.environ["TMPDIR"]).joinpath("cookies.sqlite.copy").write_text(secret)
    fail(f"Private video auth_token={secret} ct0={secret} Cookie: {secret}")
if "network-fail" in source:
    fail("network is unreachable")
if "gated" in source and browser is None:
    fail("This is a members-only video")
if "bot-check" in source and browser is None:
    fail("Sign in to confirm you're not a bot")
if "tcc-fallback" in source:
    if browser is None:
        fail("Private video")
    if browser == "safari":
        fail("Operation not permitted while reading Safari cookies")
if "firefox-lock" in source and browser == "firefox":
    fail("could not copy Firefox cookie database cookies.sqlite")

metadata = {
    "title": "Fake Video",
    "channel": "Fake Channel",
    "upload_date": "20260718",
    "duration": 75,
    "duration_string": "1:15",
    "webpage_url": source,
    "extractor": "fake",
    "availability": "public",
    "language": "de",
    "description": "Fake description",
    "subtitles": {"en": [{"ext": "vtt"}], "de": [{"ext": "vtt"}]},
    "automatic_captions": {"en": [{"ext": "vtt"}], "fr": [{"ext": "vtt"}]},
}
if "no-captions" in source:
    metadata["subtitles"] = {}
    metadata["automatic_captions"] = {}

if "--flat-playlist" in args:
    limit = 3
    if "--playlist-end" in args:
        limit = int(args[args.index("--playlist-end") + 1])
    metadata = {
        "title": "Fake Playlist",
        "webpage_url": source,
        "entries": [
            {"playlist_index": i, "title": f"Video {i}", "webpage_url": f"https://example.test/v{i}", "id": f"v{i}"}
            for i in range(1, min(limit, 3) + 1)
        ],
    }
    print(json.dumps(metadata))
    raise SystemExit(0)

if "--dump-single-json" in args:
    print(json.dumps(metadata))
    raise SystemExit(0)

if "--write-subs" in args or "--write-auto-subs" in args:
    template = args[args.index("-o") + 1]
    target = Path(template.replace("%(ext)s", "en.vtt"))
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        "WEBVTT\n\n00:00.500 --> 00:02.000\nHello <c>world</c>.\n\n"
        "00:02.000 --> 00:03.500\nSecond line.\n",
        encoding="utf-8",
    )
    raise SystemExit(0)

if "--print" in args and "after_move:filepath" in args:
    template = args[args.index("-o") + 1]
    replacements = {
        "%(playlist_title)s": "Fake Playlist",
        "%(playlist_index)03d": "001",
        "%(title)s": "Fake Video",
        "%(height)s": "720",
        "%(fps)s": "30",
        "%(ext)s": "mp4",
    }
    rendered = template
    for key, value in replacements.items():
        rendered = rendered.replace(key, value)
    target = Path(rendered)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"fake-media")
    print(target)
    if "partial-playlist" in source:
        fail("connection reset after first playlist item")
    raise SystemExit(0)

fail("unexpected fake invocation: " + " ".join(args))
''',
        encoding="utf-8",
    )
    path.chmod(0o700)


def main() -> int:
    checks: list[str] = []
    with tempfile.TemporaryDirectory(prefix="yt-fetch-selftest-") as temp:
        root = Path(temp)
        fake = root / "yt-dlp"
        make_fake_ytdlp(fake)
        log = root / "calls.jsonl"
        home = root / "home"
        home.mkdir()
        yt_fetch.RUN_ROOT = root / "runs"

        env = {
            "YTDLP": str(fake),
            "FAKE_YTDLP_LOG": str(log),
            "HOME": str(home),
            "SEEDED_COOKIE_SECRET": "seeded-cookie-canary-7f91e",
        }
        with patch.dict(os.environ, env, clear=False):
            status = yt_fetch.preflight()
            check(status["can_proceed"] and status["yt_dlp_version"] == "2026.06.09", "preflight failed")
            check(status["python"] == sys.executable, "interpreter path missing")
            checks.append("preflight")

            cases = {
                "Private video": "authentication_required",
                "Sign in to confirm you're not a bot": "bot_check",
                "not available in your country": "geo_restricted",
                "Video unavailable": "media_unavailable",
                "network is unreachable": "network_failed",
                "unable to extract signature": "extractor_failed",
                "unmatched failure": "acquisition_failed",
            }
            for diagnostic, code in cases.items():
                check(yt_fetch.classify_failure(diagnostic).code == code, f"classifier missed {code}")
            check(
                yt_fetch.classify_failure("Operation not permitted", "safari").code == "cookie_tcc_denied",
                "Safari TCC failure misclassified",
            )
            firefox = yt_fetch.classify_failure("could not copy Firefox cookie database cookies.sqlite", "firefox")
            check(firefox.code == "cookie_read_failed" and "Close Firefox" in str(firefox.repair_action), "Firefox lock misclassified")
            bot = yt_fetch.classify_failure("Sign in to confirm you're not a bot", "safari")
            check(bot.code == "bot_check" and "exposed" in str(bot.repair_action), "bot-check account warning missing")
            secret = yt_fetch.sanitize_diagnostic("auth_token=secret123 ct0=secret456 Cookie: rawcookie")
            check("secret123" not in secret and "secret456" not in secret and "rawcookie" not in secret, "secret redaction failed")
            checks.append("classification_and_redaction")

            language, kind = yt_fetch.choose_caption({
                "language": "de",
                "subtitles": {"de": [{}], "en": [{}]},
                "automatic_captions": {"en": [{}]},
            })
            check((language, kind) == ("en", "manual"), "manual English captions must win")
            language, kind = yt_fetch.choose_caption({
                "language": "de",
                "subtitles": {"de": [{}]},
                "automatic_captions": {"en": [{}]},
            })
            check((language, kind) == ("en", "automatic"), "automatic English must precede manual original")
            checks.append("caption_priority")

            vtt = root / "sample.vtt"
            vtt.write_text(
                "WEBVTT\n\n00:00.500 --> 00:01.500\nHello <c>world</c>.\n\n"
                "01:02:03.250 --> 01:02:04.000\nLater.\n",
                encoding="utf-8",
            )
            segments = yt_fetch.parse_vtt(vtt)
            check(len(segments) == 2 and segments[0]["start"] == 0.5, "VTT subsecond parsing failed")
            check(segments[1]["start"] == 3723.25, "VTT hour parsing failed")
            checks.append("vtt_parsing")

            normal = yt_fetch.run(parse_args("info", "https://example.test/video", "--desc"))
            check(normal["status"] == "ok" and normal["result"]["description"] == "Fake description", "info failed")
            check(normal["auth_events"] == [], "public info unexpectedly read cookies")
            checks.append("public_info")

            fallback = yt_fetch.run(parse_args("info", "https://example.test/tcc-fallback"))
            check(fallback["status"] == "ok", f"TCC fallback failed: {fallback.get('error')}")
            check(fallback["result"]["authenticated_with"] == "firefox", "Firefox success browser missing")
            check([event["browser"] for event in fallback["auth_events"]] == ["safari", "firefox"], "fallback order wrong")
            check(fallback["notify_user"] is True, "browser route change must notify")
            checks.append("safari_firefox_fallback")

            forced = yt_fetch.run(parse_args("info", "https://example.test/gated", "--auth"))
            check(forced["status"] == "ok" and forced["attempts"][0]["browser"] == "safari", "forced auth failed")
            check(not any("public" in attempt["method"] for attempt in forced["attempts"]), "forced auth made public attempt")
            disabled = yt_fetch.run(parse_args("info", "https://example.test/gated", "--no-browser-cookies"))
            check(disabled["error"]["code"] == "authentication_required" and not disabled["auth_events"], "cookie opt-out failed")
            conflict = yt_fetch.run(parse_args("info", "https://example.test/video", "--auth", "--no-browser-cookies"))
            check(conflict["error"]["code"] == "conflicting_auth_options", "contradictory auth flags accepted")
            bot_retry = yt_fetch.run(parse_args("info", "https://example.test/bot-check"))
            check(bot_retry["status"] == "ok" and any("account" in warning for warning in bot_retry["warnings"]), "bot retry risk not surfaced")
            leak_probe = yt_fetch.run(parse_args("info", "https://example.test/seeded-secret"))
            serialized_probe = json.dumps(leak_probe)
            check(env["SEEDED_COOKIE_SECRET"] not in serialized_probe, "seeded cookie leaked into structured output")
            check(env["SEEDED_COOKIE_SECRET"] not in log.read_text(encoding="utf-8"), "seeded cookie leaked into command log")
            check(not list(yt_fetch.RUN_ROOT.rglob("cookies.sqlite.copy")), "seeded cookie copy survived cleanup")
            for generated in root.rglob("*"):
                if generated.is_file():
                    check(env["SEEDED_COOKIE_SECRET"].encode() not in generated.read_bytes(), f"seeded cookie leaked into {generated}")
            checks.append("auth_force_optout_and_bot")

            transcript = yt_fetch.run(parse_args("transcript", "https://example.test/video", "--save"))
            check(transcript["status"] == "ok", f"transcript failed: {transcript.get('error')}")
            result = transcript["result"]
            check(result["caption_kind"] == "manual" and result["caption_language"] == "en", "caption provenance wrong")
            check(result["video_downloaded"] is False and result["audio_downloaded"] is False, "transcript downloaded media")
            saved = Path(result["saved_path"])
            check(saved.parent == home / "Downloads" and saved.is_file(), "automatic Downloads transcript route failed")
            bounded = yt_fetch.run(parse_args("transcript", "https://example.test/video", "--save", "--max-inline-chars", "8"))
            check(bounded["result"]["text_truncated"] is True and len(bounded["result"]["text"]) <= 9, "inline bound failed")
            check(bounded["result"]["segments_truncated"] is True, "timestamped segments bypassed inline bound")
            bounded_saved = Path(bounded["result"]["saved_path"])
            check(bounded_saved != saved and bounded_saved.is_file(), "collision-safe transcript save failed")
            check("Hello world." in bounded_saved.read_text(encoding="utf-8"), "inline bound truncated the saved transcript")
            no_captions = yt_fetch.run(parse_args("transcript", "https://example.test/no-captions"))
            network = yt_fetch.run(parse_args("transcript", "https://example.test/network-fail"))
            check(no_captions["error"]["code"] == "no_captions", "true no-caption state failed")
            check(network["error"]["code"] == "network_failed", "network failure collapsed into no captions")
            checks.append("transcript_and_downloads_routing")

            listing = yt_fetch.run(parse_args("list", "https://example.test/playlist", "--limit", "2"))
            check(listing["status"] == "ok" and listing["result"]["entry_count"] == 2, "playlist limit failed")
            checks.append("structured_list")

            before_log = log.read_text(encoding="utf-8").splitlines()
            single = yt_fetch.run(parse_args("get", "https://example.test/video"))
            after_log = log.read_text(encoding="utf-8").splitlines()
            last_call = json.loads(after_log[-1])
            check(single["status"] == "ok" and single["result"]["file_count"] == 1, "single download failed")
            check("--no-playlist" in last_call and "--yes-playlist" not in last_call, "single download did not disable playlists")
            playlist = yt_fetch.run(parse_args("get", "https://example.test/playlist", "--playlist", "--limit", "1"))
            check(playlist["status"] == "ok" and playlist["result"]["playlist"] is True, "explicit playlist failed")
            partial = yt_fetch.run(parse_args("get", "https://example.test/partial-playlist", "--playlist"))
            check(partial["status"] == "partial" and partial["result"]["file_count"] == 1, "partial playlist not preserved")
            checks.append("download_safety_and_verification")

            run_dir, run_id, _ = yt_fetch.create_run()
            check(stat.S_IMODE(run_dir.stat().st_mode) == 0o700, "run directory is not private")
            sentinel = run_dir / yt_fetch.RUN_SENTINEL
            sentinel.write_text(json.dumps({"run_id": run_id, "created_at": 0}), encoding="utf-8")
            foreign = yt_fetch.RUN_ROOT / "foreign-stale-directory"
            foreign.mkdir(mode=0o700)
            (foreign / yt_fetch.RUN_SENTINEL).write_text(
                json.dumps({"run_id": "not-owned-by-name", "created_at": 0}),
                encoding="utf-8",
            )
            removed = yt_fetch.sweep_stale_runs(now=time.time())
            check(str(run_dir) in removed and not run_dir.exists(), "stale run sweep failed")
            check(foreign.exists(), "stale sweep removed a directory it could not prove it owned")
            children_before = set(yt_fetch.RUN_ROOT.iterdir())
            crashed = yt_fetch.run(parse_args("info", "https://example.test/crash-temp"))
            children_after = set(yt_fetch.RUN_ROOT.iterdir())
            check(crashed["status"] == "error" and children_before == children_after, "catchable failure left temp state")
            check(not list(yt_fetch.RUN_ROOT.rglob("cookies.txt")), "temporary cookie file survived cleanup")
            checks.append("private_temp_and_cleanup")

            shim = SCRIPT_DIR / "yt-fetch.sh"
            proc = subprocess.run(
                ["bash", str(shim), "info", "https://example.test/video"],
                capture_output=True,
                text=True,
                env={**os.environ, "YT_FETCH_PYTHON": sys.executable, **env},
            )
            check(proc.returncode == 0 and json.loads(proc.stdout)["status"] == "ok", "compatibility shim failed")
            leak_cli = subprocess.run(
                ["bash", str(shim), "info", "https://example.test/seeded-secret"],
                capture_output=True,
                text=True,
                env={**os.environ, "YT_FETCH_PYTHON": sys.executable, **env},
            )
            check(leak_cli.returncode != 0 and leak_cli.stderr == "", "CLI leaked a failure diagnostic to stderr")
            check(env["SEEDED_COOKIE_SECRET"] not in leak_cli.stdout, "CLI leaked the seeded cookie canary")
            checks.append("shell_compatibility")

    print(json.dumps({"status": "ok", "checks": checks, "count": len(checks)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
