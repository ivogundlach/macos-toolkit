#!/usr/bin/env python3
"""Offline deterministic self-test for the watch skill."""
from __future__ import annotations

import json
import os
import shlex
import stat
import subprocess
import sys
import tempfile
from unittest.mock import patch
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from config import get_api_keys, init_config, preflight, read_env_file  # noqa: E402
from download import (  # noqa: E402
    AcquisitionError,
    _auth_args,
    _classify_failure,
    choose_subtitle_track,
    is_stale_ytdlp_version,
)
from runstate import CleanupError, cleanup_run, cleanup_stale, create_run, mark_keep  # noqa: E402
from transcribe import detect_visual_cues, format_transcript, parse_vtt  # noqa: E402
from frames import format_time, merge_frames  # noqa: E402
from whisper import transcribe_chunks  # noqa: E402
import whisper  # noqa: E402
import watch as watch_runtime  # noqa: E402


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def run(*args: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != expect:
        raise AssertionError(
            f"command returned {result.returncode}, expected {expect}: {args}\n"
            f"stdout={result.stdout[-1000:]}\nstderr={result.stderr[-1000:]}"
        )
    return result


def make_video(path: Path) -> None:
    run(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=2:duration=4",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=16000:duration=4",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
        str(path),
    )


def main() -> int:
    checks: list[str] = []
    with tempfile.TemporaryDirectory(prefix="watch-selftest-") as temp:
        root = Path(temp)

        missing_config = root / "config" / ".env"
        keyless = preflight(missing_config)
        check(keyless["can_proceed"] is True, "keyless preflight must pass with dependencies present")
        check(keyless["keyless"] is True, "missing config must be explicitly keyless")
        checks.append("keyless_preflight")

        config_path, created = init_config(missing_config)
        check(created and stat.S_IMODE(config_path.stat().st_mode) == 0o600, "config must be created at 0600")
        check(read_env_file(config_path)["WATCH_PREFERRED_WHISPER"] == "groq", "Groq must be preferred")
        project_env = root / ".env"
        project_env.write_text("GROQ_API_KEY=must-not-load\n", encoding="utf-8")
        previous_cwd = Path.cwd()
        try:
            os.chdir(root)
            with patch.dict(os.environ, {"GROQ_API_KEY": "", "OPENAI_API_KEY": ""}, clear=True):
                check(get_api_keys(root / "absent-watch-config") == {}, "project .env key was loaded")
        finally:
            os.chdir(previous_cwd)
        checks.append("config_permissions")
        checks.append("project_env_isolation")

        language, kind = choose_subtitle_track({
            "language": "de",
            "subtitles": {"de": [{"ext": "vtt"}], "en": [{"ext": "vtt"}]},
            "automatic_captions": {"fr": [{"ext": "vtt"}]},
        })
        check((language, kind) == ("de", "manual"), "manual original-language captions must win")
        checks.append("caption_selection")

        check(_auth_args(True) == ["--cookies-from-browser", "safari"], "auth plan must use Safari")
        check(_auth_args(True, "firefox") == ["--cookies-from-browser", "firefox"], "Firefox fallback plan missing")
        tcc = _classify_failure("ERROR: Operation not permitted while reading Safari cookies", True)
        cookie = _classify_failure("ERROR: failed to decrypt Safari cookie database", True)
        firefox_lock = _classify_failure("ERROR: could not copy Firefox cookie database cookies.sqlite", True, "firefox")
        bot = _classify_failure("ERROR: Sign in to confirm you're not a bot", False)
        auth_required = _classify_failure("ERROR: This is a members-only video", False)
        check(tcc.code == "auth_tcc_denied", "TCC denial must be classified separately")
        check(cookie.code == "auth_cookie_extraction_failed", "cookie extraction failure misclassified")
        check(firefox_lock.code == "auth_cookie_extraction_failed", "Firefox lock failure misclassified")
        check(bot.code == "bot_check" and "expose" in str(bot.repair_action), "bot check risk guidance missing")
        check(auth_required.code == "authentication_required", "true authentication barrier misclassified")
        check(is_stale_ytdlp_version("2023.07.06") is True, "stale yt-dlp version not detected")
        check(is_stale_ytdlp_version("2026.06.09") is False, "current yt-dlp version marked stale")
        checks.append("auth_plan_and_classification")

        auth_manifest = {"path_attempts": [], "privacy_events": []}
        auth_calls: list[tuple[bool, str]] = []
        def fake_cookie_fallback(auth: bool, browser: str):
            auth_calls.append((auth, browser))
            if not auth:
                raise AcquisitionError("authentication_required", "gated")
            if browser == "safari":
                raise AcquisitionError("auth_tcc_denied", "blocked")
            return {"attempts": [], "warnings": [], "secret": None}
        auth_result, auth_browser = watch_runtime._remote_with_cookie_policy(
            auth_manifest,
            "test",
            fake_cookie_fallback,
            force_auth=False,
            no_browser_cookies=False,
        )
        check(
            auth_calls == [(False, "safari"), (True, "safari"), (True, "firefox")],
            "public/Safari/Firefox retry order is wrong",
        )
        check(auth_browser == "firefox" and auth_result["auth_browser"] == "firefox", "successful cookie browser not recorded")
        check(auth_manifest["privacy_events"][-1]["status"] == "ok", "cookie success event missing")
        check("auth_token" not in json.dumps(auth_manifest).lower(), "cookie secret leaked into manifest")
        checks.append("automatic_cookie_fallback")

        vtt = root / "sample.vtt"
        vtt.write_text(
            "WEBVTT\n\n00:00.000 --> 00:01.500\nLook here at this chart.\n\n"
            "00:02.000 --> 00:03.000\nOrdinary speech.\n",
            encoding="utf-8",
        )
        segments = parse_vtt(vtt)
        check(len(segments) == 2 and "[00:00]" in format_transcript(segments), "VTT parsing failed")
        cues, cue_meta = detect_visual_cues(segments, "en", complete=True)
        check(cues == [0.0] and cue_meta["status"] == "applied", "visual cue detection failed")
        _, skipped = detect_visual_cues(segments, "de", complete=True)
        check(skipped["status"] == "skipped_language", "non-English cues must be disclosed as skipped")
        _, partial_skip = detect_visual_cues(segments, "en", complete=False)
        check(partial_skip["status"] == "skipped_partial", "partial transcript cues must be disclosed as skipped")
        checks.append("vtt_and_cues")
        checks.append("cue_skip_disclosure")

        primary_path = root / "scene.jpg"
        cue_path = root / "cue.jpg"
        primary_path.write_bytes(b"scene")
        cue_path.write_bytes(b"cue")
        merged = merge_frames(
            [{"path": str(primary_path), "timestamp_seconds": 0.5, "reason": "scene-change"}],
            [{"path": str(cue_path), "timestamp_seconds": 0.6, "reason": "transcript-cue"}],
        )
        check(len(merged) == 1 and merged[0]["reason"] == "transcript-cue", "cue/scene collision was not deduplicated")
        check(not primary_path.exists() and cue_path.exists(), "deduplication kept the wrong frame file")
        cue_path.unlink()
        check(format_time(0.5) == "00:00.5", "subsecond timestamp was rounded away")
        checks.append("frame_collision_and_subsecond_time")

        chunks = [(root / "a.mp3", 0.0, 10.0), (root / "b.mp3", 10.0, 10.0)]
        def fake_transcribe(path: Path):
            if path.name == "b.mp3":
                raise SystemExit("simulated provider failure")
            return ([{"start": 0.0, "end": 1.0, "text": "hello"}], "en")
        partial_segments, failures, detected = transcribe_chunks(chunks, fake_transcribe)
        check(len(partial_segments) == 1 and failures[0]["start"] == 10.0, "partial intervals missing")
        check(detected == "en", "transcript language metadata missing")
        checks.append("partial_transcript")

        provider_calls: list[str] = []
        def fake_extract(_video: str, output: Path) -> Path:
            output.write_bytes(b"audio")
            return output
        def fake_provider(provider: str, _key: str, _path: Path):
            provider_calls.append(provider)
            if provider == "groq":
                raise SystemExit("simulated Groq failure")
            return ([{"start": 0.0, "end": 1.0, "text": "fallback"}], "en")
        with patch.object(whisper, "extract_audio", fake_extract), \
             patch.object(whisper, "_transcribe_file", fake_provider), \
             patch.object(whisper, "get_api_keys", lambda: {"groq": "g", "openai": "o"}):
            try:
                whisper.transcribe_video(
                    str(root / "dummy.mp4"), root / "failover-off.mp3",
                    backend="groq", api_key="g", allow_failover=False,
                )
                raise AssertionError("provider failure silently failed over while consent was off")
            except SystemExit as exc:
                check("Groq failure" in str(exc), "primary failure was not preserved")
            check(provider_calls == ["groq"], "second provider was contacted without consent")
            provider_calls.clear()
            fallback_segments, fallback_meta = whisper.transcribe_video(
                str(root / "dummy.mp4"), root / "failover-on.mp3",
                backend="groq", api_key="g", allow_failover=True,
            )
            check(provider_calls == ["groq", "openai"], "explicit failover did not try both providers")
            check(fallback_segments and fallback_meta["provider_failover"] is True, "failover metadata missing")
        checks.append("provider_failover_consent")

        owned_root = root / "runs"
        owned, run_id = create_run(owned_root)
        outside = root / "outside"
        outside.mkdir()
        try:
            cleanup_run(outside, root=owned_root)
            raise AssertionError("cleanup accepted an unowned directory")
        except CleanupError:
            pass
        cleanup = cleanup_run(owned, run_id=run_id, root=owned_root)
        check(cleanup["status"] == "cleaned" and not owned.exists(), "owned cleanup failed")
        kept, kept_id = create_run(owned_root)
        mark_keep(kept, kept_id, root=owned_root)
        sentinel = kept / ".watch-run.json"
        sentinel_data = json.loads(sentinel.read_text(encoding="utf-8"))
        sentinel_data["created_at"] = 0
        sentinel.write_text(json.dumps(sentinel_data), encoding="utf-8")
        cleanup_stale(max_age_hours=0, root=owned_root)
        check(kept.exists(), "explicitly kept run was removed by stale cleanup")
        cleanup_run(kept, run_id=kept_id, root=owned_root)
        checks.append("cleanup_guard")

        video = root / "synthetic-video.mp4"
        make_video(video)
        watch = str(SCRIPT_DIR / "watch.py")
        invalid = run(sys.executable, watch, str(video), "--fps", "0", expect=1)
        invalid_manifest = json.loads(invalid.stdout)
        check(invalid_manifest["error"]["code"] == "invalid_fps", "invalid fps contract failed")
        excessive = run(sys.executable, watch, str(video), "--max-frames", "301", expect=1)
        check(json.loads(excessive.stdout)["error"]["code"] == "invalid_frame_cap", "safety cap failed")
        conflicting_auth = run(
            sys.executable,
            watch,
            "https://example.invalid/video",
            "--auth",
            "--no-browser-cookies",
            expect=1,
        )
        check(
            json.loads(conflicting_auth.stdout)["error"]["code"] == "conflicting_auth_options",
            "contradictory auth options were accepted",
        )
        checks.append("argument_validation")

        result = run(
            sys.executable,
            watch,
            str(video),
            "--detail", "efficient",
            "--max-frames", "8",
        )
        manifest = json.loads(result.stdout)
        check(manifest["schema_version"] == 1, "manifest schema version missing")
        check(
            manifest["status"] == "partial",
            f"keyless local video should disclose transcript degradation, got {manifest['status']}: {manifest.get('error')}",
        )
        check(1 <= len(manifest["frames"]) <= 8, "frame extraction count invalid")
        check(manifest["cleanup"]["required"] is True, "frame run must require cleanup")
        check(manifest["notify_user"] is True, "keyless transcript degradation must notify")
        keyless_degradation = next(item for item in manifest["degradations"] if item["code"] == "whisper_key_unavailable")
        check(bool(keyless_degradation.get("repair_action")), "keyless degradation lacks repair action")
        cleanup_command = shlex.split(manifest["cleanup"]["command"])
        cleanup_result = run(*cleanup_command)
        check(json.loads(cleanup_result.stdout)["status"] == "cleaned", "manifest cleanup command failed")
        checks.append("synthetic_video_manifest")

        alias = run(
            sys.executable, watch, str(video), "--detail", "token-burner",
            "--max-frames", "8", "--no-whisper",
        )
        alias_manifest = json.loads(alias.stdout)
        check(alias_manifest["detail"] == "complete", "legacy detail alias was not normalized")
        check(any("deprecated" in warning for warning in alias_manifest["warnings"]), "alias warning missing")
        cleanup_run(alias_manifest["run"]["dir"], run_id=alias_manifest["run"]["id"])

        unsafe = run(
            sys.executable, watch, str(video), "--detail", "complete",
            "--unsafe-max-frames", "301", "--no-whisper",
        )
        unsafe_manifest = json.loads(unsafe.stdout)
        check(unsafe_manifest["frame_selection"]["cap"] == 301, "unsafe override did not apply")
        check(unsafe_manifest["frame_selection"]["unsafe_override"] is True, "unsafe override not disclosed")
        cleanup_run(unsafe_manifest["run"]["dir"], run_id=unsafe_manifest["run"]["id"])
        checks.append("detail_alias_and_unsafe_override")

        sidecar = video.with_suffix(".vtt")
        sidecar.write_text(
            "WEBVTT\n\n00:00.500 --> 00:01.500\nAs you can see on the screen, the chart changes.\n",
            encoding="utf-8",
        )
        cue_result = run(
            sys.executable,
            watch,
            str(video),
            "--detail", "balanced",
            "--max-frames", "8",
            "--no-whisper",
        )
        cue_manifest = json.loads(cue_result.stdout)
        check(cue_manifest["cue_detection"]["status"] == "applied", "integrated auto-cue detection failed")
        check(any(frame["reason"] == "transcript-cue" for frame in cue_manifest["frames"]), "cue frame missing")
        cleanup_run(cue_manifest["run"]["dir"], run_id=cue_manifest["run"]["id"])
        checks.append("integrated_auto_cues")

    print(json.dumps({"status": "ok", "checks": checks, "count": len(checks)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
