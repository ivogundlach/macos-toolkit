#!/usr/bin/env python3
"""Parse timestamped captions and select conservative visual-cue moments."""
from __future__ import annotations

import html
import re
import sys
from pathlib import Path


TS_RE = re.compile(
    r"(?:(\d{1,2}):)?(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+"
    r"(?:(\d{1,2}):)?(\d{2}):(\d{2})[.,](\d{3})"
)
TAG_RE = re.compile(r"<[^>]+>")
VISUAL_CUE_RE = re.compile(
    r"\b(?:look (?:here|at this|at that)|as you can see|you can see (?:here|that)|"
    r"notice (?:this|that|here)|watch what happens|on (?:the|this) screen|"
    r"shown (?:here|on screen)|this (?:chart|graph|slide|diagram|image))\b",
    re.IGNORECASE,
)


def _to_seconds(hours: str | None, minutes: str, seconds: str, millis: str) -> float:
    return int(hours or 0) * 3600 + int(minutes) * 60 + int(seconds) + int(millis) / 1000.0


def parse_vtt(path: str | Path) -> list[dict]:
    text = Path(path).read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    segments: list[dict] = []
    index = 0
    while index < len(lines):
        match = TS_RE.search(lines[index])
        if not match:
            index += 1
            continue
        groups = match.groups()
        start = _to_seconds(*groups[:4])
        end = _to_seconds(*groups[4:])
        index += 1
        cue_lines: list[str] = []
        while index < len(lines) and lines[index].strip():
            cleaned = html.unescape(TAG_RE.sub("", lines[index])).strip()
            if cleaned:
                cue_lines.append(cleaned)
            index += 1
        cue_text = re.sub(r"\s+", " ", " ".join(cue_lines)).strip()
        if cue_text:
            segments.append({"start": round(start, 2), "end": round(end, 2), "text": cue_text})
        index += 1
    return _dedupe(segments)


def _dedupe(segments: list[dict]) -> list[dict]:
    out: list[dict] = []
    for segment in segments:
        if out and segment["text"] == out[-1]["text"]:
            out[-1]["end"] = segment["end"]
            continue
        if out and segment["text"].startswith(out[-1]["text"] + " "):
            out[-1]["text"] = segment["text"]
            out[-1]["end"] = segment["end"]
            continue
        out.append(segment)
    return out


def filter_range(
    segments: list[dict], start_seconds: float | None, end_seconds: float | None
) -> list[dict]:
    if start_seconds is None and end_seconds is None:
        return segments
    low = start_seconds if start_seconds is not None else float("-inf")
    high = end_seconds if end_seconds is not None else float("inf")
    return [segment for segment in segments if segment["end"] >= low and segment["start"] <= high]


def format_timestamp(seconds: float) -> str:
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    remaining = seconds % 60
    if abs(remaining - round(remaining)) < 0.05:
        second_text = f"{int(round(remaining)):02d}"
    else:
        second_text = f"{remaining:04.1f}"
    if hours:
        return f"{hours}:{minutes:02d}:{second_text}"
    return f"{minutes:02d}:{second_text}"


def format_transcript(segments: list[dict]) -> str:
    return "\n".join(f"[{format_timestamp(segment['start'])}] {segment['text']}" for segment in segments)


def detect_visual_cues(
    segments: list[dict],
    language: str | None,
    *,
    complete: bool,
    max_cues: int = 8,
    minimum_spacing: float = 2.0,
) -> tuple[list[float], dict[str, object]]:
    if not complete:
        return [], {"status": "skipped_partial", "language": language, "count": 0}
    normalized = (language or "").lower()
    if normalized and normalized != "en" and not normalized.startswith("en-"):
        return [], {"status": "skipped_language", "language": language, "count": 0}
    cues: list[float] = []
    for segment in segments:
        if not VISUAL_CUE_RE.search(segment.get("text", "")):
            continue
        timestamp = float(segment.get("start", 0.0))
        if cues and timestamp - cues[-1] < minimum_spacing:
            continue
        cues.append(timestamp)
        if len(cues) >= max_cues:
            break
    return cues, {
        "status": "applied" if cues else "none_found",
        "language": language or "unknown_assumed_english",
        "count": len(cues),
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: transcribe.py <vtt-path>", file=sys.stderr)
        raise SystemExit(2)
    print(format_transcript(parse_vtt(sys.argv[1])))
