#!/usr/bin/env python3
"""Single structured entrypoint for visual video understanding."""
from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from config import (  # noqa: E402
    SAFE_FRAME_CAP,
    SCHEMA_VERSION,
    frame_cap,
    get_api_keys,
    get_config,
    normalize_detail,
    preflight,
)
from download import AcquisitionError, download, fetch_captions, is_url, resolve_local  # noqa: E402
from frames import (  # noqa: E402
    MAX_FPS,
    auto_fps,
    auto_fps_focus,
    extract_at_timestamps,
    extract_keyframes,
    extract_scene_or_uniform,
    format_time,
    get_metadata,
    merge_frames,
    parse_time,
    parse_timestamps,
)
from runstate import cleanup_run, cleanup_stale, create_run, mark_keep  # noqa: E402
from transcribe import detect_visual_cues, filter_range, format_transcript, parse_vtt  # noqa: E402
from whisper import transcribe_video  # noqa: E402

COOKIE_BROWSERS = ("safari", "firefox")
COOKIE_RETRY_CODES = {"authentication_required", "bot_check"}
COOKIE_NEXT_BROWSER_CODES = {
    "auth_tcc_denied",
    "auth_cookie_extraction_failed",
    "authentication_required",
    "bot_check",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Acquire video evidence as a versioned JSON manifest.")
    parser.add_argument("source", help="Video URL or local file path")
    parser.add_argument("--detail", choices=["transcript", "efficient", "balanced", "complete", "token-burner"])
    parser.add_argument("--max-frames", type=int, help=f"Frame cap up to {SAFE_FRAME_CAP}")
    parser.add_argument("--unsafe-max-frames", type=int, help="Explicitly exceed the normal safety cap")
    parser.add_argument("--resolution", type=int, default=512)
    parser.add_argument("--fps", type=float)
    parser.add_argument("--timestamps", help="Comma-separated absolute timestamps")
    parser.add_argument("--start")
    parser.add_argument("--end")
    parser.add_argument("--auth", action="store_true", help="Force Safari/Firefox cookie authentication")
    parser.add_argument("--no-browser-cookies", action="store_true", help="Disable automatic browser-cookie retry")
    parser.add_argument("--whisper", choices=["groq", "openai"])
    parser.add_argument("--allow-provider-failover", action="store_true")
    parser.add_argument("--no-whisper", action="store_true")
    parser.add_argument("--no-auto-cues", action="store_true")
    parser.add_argument("--no-dedup", action="store_true")
    parser.add_argument("--keep-run", action="store_true")
    parser.add_argument("--format", choices=["json", "markdown"], default="json")
    return parser


def _error_manifest(code: str, message: str, repair_action: str | None = None) -> dict[str, object]:
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "error",
        "notify_user": True,
        "error": {"code": code, "message": message, "repair_action": repair_action},
        "warnings": [],
        "degradations": [],
    }


def _validate_args(args: argparse.Namespace, status: dict[str, object]) -> dict[str, object] | None:
    if not status["can_proceed"]:
        return _error_manifest("preflight_failed", "watch dependencies or config need repair", status["repair_action"])
    if args.resolution <= 0 or args.resolution > 4096:
        return _error_manifest("invalid_resolution", "--resolution must be between 1 and 4096")
    if args.fps is not None and args.fps <= 0:
        return _error_manifest("invalid_fps", "--fps must be greater than zero")
    if args.max_frames is not None and (args.max_frames <= 0 or args.max_frames > SAFE_FRAME_CAP):
        return _error_manifest(
            "invalid_frame_cap",
            f"--max-frames must be between 1 and {SAFE_FRAME_CAP}; use --unsafe-max-frames for an explicit higher override",
        )
    if args.unsafe_max_frames is not None and args.unsafe_max_frames <= 0:
        return _error_manifest("invalid_unsafe_frame_cap", "--unsafe-max-frames must be greater than zero")
    if args.max_frames is not None and args.unsafe_max_frames is not None:
        return _error_manifest("conflicting_frame_caps", "Use only one frame-cap option")
    if args.auth and not is_url(args.source):
        return _error_manifest("auth_local_source", "--auth applies only to remote URLs")
    if args.auth and args.no_browser_cookies:
        return _error_manifest(
            "conflicting_auth_options",
            "--auth and --no-browser-cookies are contradictory; use only one",
        )
    if not is_url(args.source):
        candidate = Path(args.source).expanduser()
        if not candidate.exists() or not candidate.is_file():
            return _error_manifest("file_not_found", f"Local video not found: {candidate.resolve()}")
    try:
        start = parse_time(args.start)
        end = parse_time(args.end)
        timestamps = parse_timestamps(args.timestamps)
    except SystemExit as exc:
        return _error_manifest("invalid_timestamp", str(exc))
    if start is not None and start < 0:
        return _error_manifest("invalid_start", "--start must be non-negative")
    if end is not None and end < 0:
        return _error_manifest("invalid_end", "--end must be non-negative")
    if end is not None and start is not None and end <= start:
        return _error_manifest("invalid_range", "--end must be greater than --start")
    if any(timestamp < 0 for timestamp in timestamps):
        return _error_manifest("invalid_timestamp", "--timestamps values must be non-negative")
    args.start_seconds = start
    args.end_seconds = end
    args.explicit_timestamps = timestamps
    return None


def _append_acquisition(manifest: dict, result: dict[str, object]) -> None:
    manifest["path_attempts"].extend(result.get("attempts") or [])
    manifest["warnings"].extend(warning for warning in (result.get("warnings") or []) if warning)


def _remote_with_cookie_policy(
    manifest: dict[str, object],
    method: str,
    acquire,
    *,
    force_auth: bool,
    no_browser_cookies: bool,
    preferred_browser: str | None = None,
) -> tuple[dict[str, object], str | None]:
    trigger_code = "forced_auth" if force_auth else None
    if not force_auth:
        try:
            return acquire(False, "safari"), None
        except AcquisitionError as exc:
            manifest["path_attempts"].append({
                "method": f"{method}_public",
                "status": "failed",
                "error_code": exc.code,
            })
            if exc.code not in COOKIE_RETRY_CODES or no_browser_cookies:
                if no_browser_cookies and exc.code in COOKIE_RETRY_CODES:
                    exc.repair_action = (
                        "Remove --no-browser-cookies to permit the automatic Safari/Firefox retry, "
                        "or provide a public source."
                    )
                raise
            trigger_code = exc.code

    browsers = list(COOKIE_BROWSERS)
    if preferred_browser in browsers:
        browsers.remove(preferred_browser)
        browsers.insert(0, preferred_browser)
    last_error: AcquisitionError | None = None
    for browser in browsers:
        event = {
            "type": "browser_cookie_read",
            "browser": browser,
            "persisted": False,
            "reason": trigger_code,
            "status": "attempted",
        }
        manifest["privacy_events"].append(event)
        try:
            result = acquire(True, browser)
        except AcquisitionError as exc:
            last_error = exc
            event["status"] = "failed"
            event["error_code"] = exc.code
            manifest["path_attempts"].append({
                "method": f"{method}_authenticated",
                "browser": browser,
                "status": "failed",
                "error_code": exc.code,
            })
            if exc.code in COOKIE_NEXT_BROWSER_CODES:
                continue
            raise
        event["status"] = "ok"
        result["auth_browser"] = browser
        return result, browser
    if last_error is not None:
        raise last_error
    raise AcquisitionError("authentication_failed", "No browser-cookie authentication path ran")


def _render_markdown(manifest: dict[str, object]) -> str:
    lines = ["# watch result", ""]
    lines.append(f"- Status: **{manifest['status']}**")
    lines.append(f"- Source: `{manifest.get('source')}`")
    media = manifest.get("media") or {}
    if media.get("title"):
        lines.append(f"- Title: {media['title']}")
    if media.get("duration_seconds") is not None:
        lines.append(f"- Duration: {format_time(float(media['duration_seconds']))}")
    transcript = manifest.get("transcript") or {}
    lines.append(f"- Transcript: {transcript.get('source') or 'none'}; complete={transcript.get('complete')}")
    lines.append(f"- Frames: {len(manifest.get('frames') or [])}")
    if manifest.get("notify_user"):
        lines.append("- Notification required: yes")
    if manifest.get("frames"):
        lines.extend(["", "## Frames", ""])
        for frame in manifest["frames"]:
            lines.append(f"- `{frame['path']}` at {frame['timestamp']} ({frame['reason']})")
    if transcript.get("text"):
        lines.extend(["", "## Transcript", "", "```text", transcript["text"], "```"])
    if manifest.get("cleanup"):
        lines.extend(["", f"Cleanup: `{manifest['cleanup'].get('command')}`"])
    return "\n".join(lines)


def run(args: argparse.Namespace) -> dict[str, object]:
    status = preflight()
    invalid = _validate_args(args, status)
    if invalid:
        invalid["preflight"] = status
        return invalid

    stale = cleanup_stale()
    run_dir, run_id = create_run()
    manifest: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "source": args.source,
        "detail": normalize_detail(args.detail or str(get_config()["detail"])),
        "notify_user": False,
        "untrusted_evidence": True,
        "preflight": status,
        "run": {"id": run_id, "dir": str(run_dir), "stale_runs_removed": len(stale)},
        "path_attempts": [],
        "privacy_events": [],
        "warnings": [],
        "degradations": [],
        "frames": [],
    }
    if args.detail == "token-burner":
        manifest["warnings"].append("token-burner is deprecated; using complete detail")

    try:
        url_source = is_url(args.source)
        if url_source:
            acquired, caption_browser = _remote_with_cookie_policy(
                manifest,
                "captions",
                lambda auth, browser: fetch_captions(
                    args.source, run_dir / "download", auth=auth, browser=browser
                ),
                force_auth=args.auth,
                no_browser_cookies=args.no_browser_cookies,
            )
            _append_acquisition(manifest, acquired)
        else:
            acquired = resolve_local(args.source)
            caption_browser = None
            _append_acquisition(manifest, acquired)

        info = dict(acquired.get("info") or {})
        transcript_segments: list[dict] = []
        transcript_source: str | None = None
        transcript_language = acquired.get("caption_language")
        transcript_complete = True
        failed_intervals: list[dict] = []
        if acquired.get("subtitle_path"):
            try:
                transcript_segments = parse_vtt(str(acquired["subtitle_path"]))
                transcript_source = f"captions:{acquired.get('caption_kind') or 'native'}"
            except (OSError, ValueError) as exc:
                manifest["degradations"].append({
                    "code": "caption_parse_failed",
                    "message": str(exc),
                    "repair_action": "Update yt-dlp and retry; if the caption file remains malformed, use Groq transcription or visual frames.",
                })

        config = get_config()
        api_keys = get_api_keys()
        chosen_provider = args.whisper or str(config["preferred_whisper"])
        if not args.whisper and chosen_provider not in api_keys and api_keys:
            chosen_provider = next(
                provider for provider in ("groq", "openai") if provider in api_keys
            )
        whisper_available = chosen_provider in api_keys
        explicit_frames = bool(args.explicit_timestamps)
        detail = str(manifest["detail"])
        need_visual_media = detail != "transcript" or explicit_frames
        need_whisper_media = not transcript_segments and not args.no_whisper and whisper_available
        need_media = need_visual_media or need_whisper_media

        video_path: str | None = str(acquired.get("video_path")) if acquired.get("video_path") else None
        if url_source and need_media:
            media_result, _media_browser = _remote_with_cookie_policy(
                manifest,
                "media",
                lambda auth, browser: download(
                    args.source,
                    run_dir / "download",
                    audio_only=detail == "transcript" and not explicit_frames,
                    auth=auth,
                    browser=browser,
                ),
                force_auth=args.auth or caption_browser is not None,
                no_browser_cookies=args.no_browser_cookies,
                preferred_browser=caption_browser,
            )
            _append_acquisition(manifest, media_result)
            video_path = str(media_result["video_path"])
            for key, value in (media_result.get("info") or {}).items():
                if value is not None:
                    info[key] = value

        if video_path:
            metadata = get_metadata(video_path)
        else:
            metadata = {
                "duration_seconds": float(info.get("duration") or 0),
                "width": None,
                "height": None,
                "codec": None,
                "has_audio": False,
            }
        duration = float(metadata.get("duration_seconds") or 0)

        start_seconds = args.start_seconds
        end_seconds = args.end_seconds
        if duration > 0:
            if start_seconds is not None and start_seconds >= duration:
                raise AcquisitionError(
                    "range_past_end",
                    f"--start {start_seconds:.1f}s is past the end of the video ({duration:.1f}s)",
                )
            if end_seconds is not None and end_seconds > duration:
                manifest["warnings"].append(
                    f"Requested end {end_seconds:.1f}s was clamped to media duration {duration:.1f}s."
                )
                end_seconds = duration
        elif end_seconds is not None:
            manifest["warnings"].append("Media duration is unknown; requested end could not be clamped.")

        if (
            not transcript_segments
            and not args.no_whisper
            and video_path
            and metadata.get("has_audio")
            and whisper_available
        ):
            try:
                transcript_segments, whisper_meta = transcribe_video(
                    video_path,
                    run_dir / "audio.mp3",
                    backend=chosen_provider,
                    api_key=api_keys[chosen_provider],
                    allow_failover=args.allow_provider_failover or bool(config["allow_provider_failover"]),
                )
                transcript_source = f"whisper:{whisper_meta['backend']}"
                transcript_language = whisper_meta.get("language")
                transcript_complete = bool(whisper_meta["complete"])
                failed_intervals = list(whisper_meta["failed_intervals"])
                for provider in whisper_meta["providers_uploaded_to"]:
                    manifest["privacy_events"].append({
                        "type": "audio_upload",
                        "provider": provider,
                        "video_uploaded": False,
                    })
                if whisper_meta["provider_failover"]:
                    manifest["degradations"].append({
                        "code": "whisper_provider_failover",
                        "message": "Audio was sent to a second provider after the preferred provider failed.",
                    })
                if failed_intervals:
                    manifest["degradations"].append({
                        "code": "partial_transcript",
                        "message": "One or more Whisper chunks failed.",
                        "failed_intervals": failed_intervals,
                        "repair_action": "Retry the same provider for the listed intervals; enable cross-provider failover only with explicit consent.",
                    })
            except SystemExit as exc:
                transcript_complete = False
                manifest["degradations"].append({
                    "code": "whisper_failed",
                    "message": str(exc),
                    "repair_action": "Verify the configured provider key and quota, then retry; frames remain available in balanced mode.",
                })
        elif not transcript_segments:
            transcript_complete = False
            if not args.no_whisper and not whisper_available:
                manifest["degradations"].append({
                    "code": "whisper_key_unavailable",
                    "message": f"No {chosen_provider} API key is configured; continuing without API transcription.",
                    "repair_action": "Later, add GROQ_API_KEY to ~/.config/watch/.env and keep the file at mode 0600.",
                })

        if (start_seconds is not None or end_seconds is not None) and transcript_segments:
            transcript_segments = filter_range(transcript_segments, start_seconds, end_seconds)

        auto_cues: list[float] = []
        cue_detection = {"status": "disabled", "count": 0}
        if (
            detail != "transcript"
            and transcript_segments
            and bool(config["auto_cues"])
            and not args.no_auto_cues
        ):
            auto_cues, cue_detection = detect_visual_cues(
                transcript_segments,
                str(transcript_language) if transcript_language else None,
                complete=transcript_complete,
            )
        elif transcript_segments and detail != "transcript":
            cue_detection = {"status": "disabled", "count": 0, "language": transcript_language}
        manifest["cue_detection"] = cue_detection
        if str(cue_detection.get("status", "")).startswith("skipped"):
            manifest["degradations"].append({
                "code": "auto_cues_" + str(cue_detection["status"]),
                "message": "Automatic visual-cue extraction was skipped.",
                "repair_action": "Pass explicit --timestamps for the visual moments that matter.",
            })

        cue_timestamps = sorted(set([*args.explicit_timestamps, *auto_cues]))
        cap = args.unsafe_max_frames or args.max_frames or frame_cap(detail)
        unsafe_override = args.unsafe_max_frames is not None
        if unsafe_override:
            manifest["warnings"].append(
                f"Unsafe frame override explicitly raised the cap to {args.unsafe_max_frames}."
            )

        effective_start = start_seconds or 0.0
        effective_end = end_seconds if end_seconds is not None else duration
        effective_duration = max(0.0, effective_end - effective_start)
        focused = start_seconds is not None or end_seconds is not None
        budget_cap = int(cap or SAFE_FRAME_CAP)
        fps, target = (
            auto_fps_focus(effective_duration, max_frames=budget_cap)
            if focused
            else auto_fps(effective_duration, max_frames=budget_cap)
        )
        if args.fps is not None:
            fps = min(args.fps, MAX_FPS)
            target = max(1, min(budget_cap, int(round(fps * max(effective_duration, 0.5)))))

        frames: list[dict] = []
        frame_meta: dict[str, object] = {
            "engine": "none", "candidate_count": 0, "selected_count": 0, "fallback": False
        }
        cue_meta: dict[str, object] = {}
        if cue_timestamps and video_path:
            cue_frames, cue_meta = extract_at_timestamps(
                video_path,
                run_dir / "frames",
                cue_timestamps,
                resolution=args.resolution,
                max_frames=cap,
                start_seconds=start_seconds,
                end_seconds=end_seconds,
            )
            frames = cue_frames
            if cue_meta.get("failed_timestamps"):
                manifest["degradations"].append({
                    "code": "cue_frame_extraction_failed",
                    "failed_timestamps": cue_meta["failed_timestamps"],
                    "repair_action": "Retry the listed timestamps against the local media file, optionally at a lower resolution.",
                })

        detail_budget = cap if cap is None else max(0, int(cap) - len(frames))
        if detail != "transcript" and video_path and detail_budget != 0:
            if detail == "efficient":
                selected, frame_meta = extract_keyframes(
                    video_path,
                    run_dir / "frames",
                    resolution=args.resolution,
                    max_frames=detail_budget,
                    start_seconds=start_seconds,
                    end_seconds=end_seconds,
                    dedup=not args.no_dedup,
                )
            else:
                selected, frame_meta = extract_scene_or_uniform(
                    video_path,
                    run_dir / "frames",
                    fps=fps,
                    target_frames=target,
                    resolution=args.resolution,
                    max_frames=detail_budget,
                    start_seconds=start_seconds,
                    end_seconds=end_seconds,
                    dedup=not args.no_dedup,
                )
            frames = merge_frames(selected, frames)

        manifest["media"] = {
            **info,
            "duration_seconds": duration if duration > 0 else None,
            "width": metadata.get("width"),
            "height": metadata.get("height"),
            "codec": metadata.get("codec"),
            "focus_start": start_seconds,
            "focus_end": end_seconds,
        }
        manifest["transcript"] = {
            "source": transcript_source,
            "language": transcript_language,
            "complete": transcript_complete and bool(transcript_segments),
            "failed_intervals": failed_intervals,
            "segment_count": len(transcript_segments),
            "text": format_transcript(transcript_segments) if transcript_segments else None,
        }
        manifest["frame_selection"] = {
            **frame_meta,
            "cue": cue_meta,
            "fps": fps,
            "target": target,
            "cap": cap,
            "unsafe_override": unsafe_override,
        }
        manifest["frames"] = [
            {
                "path": frame["path"],
                "timestamp_seconds": frame["timestamp_seconds"],
                "timestamp": format_time(frame["timestamp_seconds"]),
                "reason": frame.get("reason", "selected"),
            }
            for frame in frames
        ]

        if not transcript_segments and not frames:
            manifest["status"] = "error"
            manifest["error"] = {
                "code": "no_evidence",
                "message": "No transcript or frames were produced.",
                "repair_action": "Use balanced detail for frames or later configure GROQ_API_KEY for captionless audio.",
            }
        elif manifest["degradations"]:
            manifest["status"] = "partial"
        privacy_requires_notice = any(
            event.get("type") == "audio_upload" or event.get("status") == "failed"
            for event in manifest["privacy_events"]
        )
        manifest["notify_user"] = bool(
            manifest["status"] != "ok"
            or manifest["degradations"]
            or privacy_requires_notice
            or manifest["warnings"]
        )

        needs_files = bool(frames)
        if needs_files or args.keep_run:
            if args.keep_run:
                mark_keep(run_dir, run_id)
            manifest["cleanup"] = {
                "required": not args.keep_run,
                "retained": True,
                "command": " ".join([
                    "python3",
                    shlex.quote(str(SCRIPT_DIR / "runstate.py")),
                    "cleanup",
                    shlex.quote(str(run_dir)),
                    "--run-id",
                    shlex.quote(run_id),
                ]),
            }
            (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        else:
            cleanup_run(run_dir, run_id=run_id)
            manifest["run"]["dir"] = None
            manifest["cleanup"] = {"required": False, "retained": False, "command": None}
        return manifest

    except AcquisitionError as exc:
        manifest["status"] = "error"
        manifest["notify_user"] = True
        manifest["error"] = exc.as_dict()
        if not any(
            attempt.get("status") == "failed" and attempt.get("error_code") == exc.code
            for attempt in manifest["path_attempts"]
        ):
            manifest["path_attempts"].append({
                "method": "yt_dlp_authenticated" if args.auth else "yt_dlp_public",
                "status": "failed",
                "error_code": exc.code,
            })
        try:
            cleanup_run(run_dir, run_id=run_id)
            manifest["run"]["dir"] = None
        except Exception as cleanup_error:
            manifest["warnings"].append(f"Failed to clean error run: {cleanup_error}")
        return manifest
    except SystemExit as exc:
        manifest["status"] = "error"
        manifest["notify_user"] = True
        manifest["error"] = {
            "code": "processing_failed",
            "message": str(exc),
            "repair_action": "Run scripts/selftest.py, verify ffmpeg/ffprobe can read the source, then retry the same request.",
        }
        try:
            cleanup_run(run_dir, run_id=run_id)
            manifest["run"]["dir"] = None
        except Exception as cleanup_error:
            manifest["warnings"].append(f"Failed to clean error run: {cleanup_error}")
        return manifest
    except Exception as exc:
        manifest["status"] = "error"
        manifest["notify_user"] = True
        manifest["error"] = {
            "code": "unexpected_processing_failure",
            "message": f"{type(exc).__name__}: {exc}",
            "repair_action": "Run the watch self-test and inspect this error before retrying.",
        }
        try:
            cleanup_run(run_dir, run_id=run_id)
            manifest["run"]["dir"] = None
        except Exception as cleanup_error:
            manifest["warnings"].append(f"Failed to clean error run: {cleanup_error}")
        return manifest


def main() -> int:
    args = build_parser().parse_args()
    manifest = run(args)
    if args.format == "markdown":
        print(_render_markdown(manifest))
    else:
        print(json.dumps(manifest, indent=2))
    return 0 if manifest.get("status") in {"ok", "partial"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
