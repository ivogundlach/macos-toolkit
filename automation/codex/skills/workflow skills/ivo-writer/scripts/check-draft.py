#!/usr/bin/env python3
"""Local deterministic checks for ivo-writer drafts."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Pattern


SCHEMA_VERSION = 2
ERROR_CODES = {
    "banned_lexicon",
    "banned_starter",
    "banned_cliche",
    "smart_quotes",
    "assistant_residue",
    "todo_marker",
    "bracket_placeholder",
    "manual_ivo_signature",
}
EVENT_CODES = {
    "exact_triad",
    "participle_tail",
    "negative_parallelism",
    "canned_conclusion",
    "false_range",
}
EMITTED_CODES = ERROR_CODES | {"style_cluster"}
IGNORABLE_CODES = ERROR_CODES | EVENT_CODES | {"style_cluster"}

BANNED_WORDS = (
    "underscore", "highlight", "showcase", "foster", "enhance", "bolster",
    "epitomize", "encapsulate", "delve", "tapestry", "landscape",
    "testament", "interplay", "intricacies", "nuances", "synergy",
    "evolution", "pivotal", "crucial", "meticulous", "vibrant", "robust",
    "multifaceted", "comprehensive", "enduring", "groundbreaking",
)
BANNED_STARTERS = ("Additionally", "Moreover", "Furthermore", "Notably")
BANNED_CLICHES = (
    "a testament to",
    "stands as a reminder",
    "marking a shift",
    "setting the stage",
)
ASSISTANT_RESIDUE = (
    "here is the draft",
    "here's the draft",
    "here is the revised version",
    "let me know if you need changes",
    "let me know if you'd like changes",
    "i can also revise",
)
SMART_QUOTES = "“”‘’"

WORD_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(word) for word in BANNED_WORDS) + r")\b",
    re.IGNORECASE,
)
STARTER_PATTERN = re.compile(
    r"(?:^|[.!?]\s+)(" + "|".join(BANNED_STARTERS) + r")\b",
    re.IGNORECASE | re.MULTILINE,
)
CLICHE_PATTERN = re.compile(
    "|".join(re.escape(phrase) for phrase in BANNED_CLICHES),
    re.IGNORECASE,
)
RESIDUE_PATTERN = re.compile(
    "|".join(re.escape(phrase) for phrase in ASSISTANT_RESIDUE),
    re.IGNORECASE,
)
TODO_PATTERN = re.compile(r"\b(?:TODO|TBD)\b", re.IGNORECASE)
BRACKET_PLACEHOLDER_PATTERN = re.compile(
    r"\[(?:add|insert|your|recipient|name|date|number|details|placeholder)"
    r"[^\]\n]{0,40}\]",
    re.IGNORECASE,
)
EVENT_PATTERNS: tuple[tuple[str, Pattern[str]], ...] = (
    (
        "exact_triad",
        re.compile(
            r"\b[\w'-]+(?:\s+[\w'-]+){0,2},\s+"
            r"[\w'-]+(?:\s+[\w'-]+){0,2},\s+"
            r"(?:and|or)\s+[\w'-]+(?:\s+[\w'-]+){0,2}\b",
            re.IGNORECASE,
        ),
    ),
    (
        "participle_tail",
        re.compile(
            r",\s+(?:thus\s+)?[\w'-]+ing\b[^.!?\n]{0,60}[.!?](?=\s|$)",
            re.IGNORECASE,
        ),
    ),
    (
        "negative_parallelism",
        re.compile(
            r"\bnot only\b[^.!?\n]{0,100}\bbut also\b|"
            r"\bit is not\b[^.!?\n]{0,100}\bbut rather\b",
            re.IGNORECASE,
        ),
    ),
    (
        "canned_conclusion",
        re.compile(
            r"\bdespite\b[^.!?\n]{0,120}\bcontinues? to thrive\b",
            re.IGNORECASE,
        ),
    ),
    (
        "false_range",
        re.compile(
            r"\bfrom\s+[^,.;:\n]{1,50}\s+to\s+[^,.;:\n]{1,50}",
            re.IGNORECASE,
        ),
    ),
)


class InvocationError(Exception):
    """Invalid caller arguments or input."""


@dataclass(frozen=True)
class Event:
    code: str
    position: int
    line: int
    column: int


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise InvocationError(message)


def parser() -> argparse.ArgumentParser:
    result = JsonArgumentParser(
        description=(
            "Check an ivo-writer draft locally. Exit 0=pass, 1=needs review, "
            "2=invocation/input error, 3=internal error."
        )
    )
    result.add_argument("--mode", required=True, choices=("correspondence", "document"))
    result.add_argument("--file", type=Path, help="Read UTF-8 text from this file instead of stdin")
    result.add_argument("--assert-authorship", action="store_true")
    result.add_argument("--assert-non-assessed", action="store_true")
    result.add_argument("--show-snippets", action="store_true")
    result.add_argument("--ignore-rule", action="append", default=[], metavar="CODE")
    return result


def error_payload(code: str, message: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "error",
        "error": {"code": code, "message": message},
        "disclaimer": (
            "This local checker does not verify facts, authorship, originality, "
            "academic-policy compliance, or detector outcomes."
        ),
    }


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True))


def read_text(path: Path | None) -> str:
    try:
        raw = path.read_bytes() if path is not None else sys.stdin.buffer.read()
    except (OSError, ValueError) as exc:
        raise InvocationError(f"Unable to read input: {exc.__class__.__name__}") from exc
    try:
        return raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise InvocationError("Input is not valid UTF-8.") from exc


def line_column(text: str, position: int) -> tuple[int, int]:
    """Return 1-based line and Unicode-codepoint column."""
    line = text.count("\n", 0, position) + 1
    last_newline = text.rfind("\n", 0, position)
    column = position + 1 if last_newline < 0 else position - last_newline
    return line, column


def snippet(text: str, position: int, limit: int = 60) -> str:
    line_start = text.rfind("\n", 0, position) + 1
    line_end = text.find("\n", position)
    if line_end < 0:
        line_end = len(text)
    value = text[line_start:line_end].strip()
    if len(value) <= limit:
        return value
    relative = max(0, position - line_start)
    start = max(0, relative - limit // 2)
    end = min(len(value), start + limit)
    bounded = value[start:end]
    return ("..." if start else "") + bounded + ("..." if end < len(value) else "")


def finding(
    code: str,
    severity: str,
    text: str,
    position: int,
    show_snippets: bool,
) -> dict[str, Any]:
    line, column = line_column(text, position)
    result: dict[str, Any] = {
        "code": code,
        "severity": severity,
        "line": line,
        "column": column,
    }
    if show_snippets:
        result["snippet"] = snippet(text, position)
    return result


def regex_findings(
    code: str,
    pattern: Pattern[str],
    text: str,
    show_snippets: bool,
    group: int = 0,
) -> list[dict[str, Any]]:
    return [
        finding(code, "error", text, match.start(group), show_snippets)
        for match in pattern.finditer(text)
    ]


def manual_signature_findings(text: str, show_snippets: bool) -> list[dict[str, Any]]:
    lines = text.splitlines(keepends=True)
    offsets: list[int] = []
    position = 0
    for value in lines:
        offsets.append(position)
        position += len(value)
    candidates: list[tuple[int, str]] = []
    for index, raw in enumerate(lines):
        stripped = raw.strip()
        if not stripped or stripped.startswith(">"):
            continue
        if re.match(r"^On .+ wrote:$", stripped, re.IGNORECASE):
            continue
        candidates.append((index, stripped))
    findings: list[dict[str, Any]] = []
    for index, stripped in candidates[-5:]:
        if re.fullmatch(r"(?:--?\s*)?Ivo[.,]?", stripped, re.IGNORECASE):
            relative = lines[index].lower().find("ivo")
            findings.append(
                finding(
                    "manual_ivo_signature",
                    "error",
                    text,
                    offsets[index] + max(relative, 0),
                    show_snippets,
                )
            )
    return findings


def detector_events(text: str, ignored: set[str]) -> list[Event]:
    events: list[Event] = []
    for code, pattern in EVENT_PATTERNS:
        if code in ignored:
            continue
        for match in pattern.finditer(text):
            line, column = line_column(text, match.start())
            events.append(Event(code, match.start(), line, column))
    unique: dict[tuple[str, int], Event] = {}
    for event in events:
        unique.setdefault((event.code, event.line), event)
    return sorted(unique.values(), key=lambda item: (item.line, item.column, item.code))


def clustered_findings(
    text: str,
    events: list[Event],
    ignored: set[str],
    show_snippets: bool,
) -> tuple[list[dict[str, Any]], int]:
    output: list[dict[str, Any]] = []
    suppressed = 0
    index = 0
    while index < len(events):
        anchor = events[index]
        end = index + 1
        while end < len(events) and events[end].line <= anchor.line + 7:
            end += 1
        window = events[index:end]
        if len(window) >= 2:
            if "style_cluster" not in ignored:
                output.append(
                    finding("style_cluster", "warning", text, anchor.position, show_snippets)
                )
        else:
            suppressed += 1
        index = end
    return output, suppressed


def analyze(
    text: str,
    mode: str,
    asserted_authorship: bool,
    asserted_non_assessed: bool,
    show_snippets: bool,
    ignored: set[str],
) -> dict[str, Any]:
    findings: list[dict[str, Any]] = []
    if "banned_lexicon" not in ignored:
        findings.extend(regex_findings("banned_lexicon", WORD_PATTERN, text, show_snippets))
    if "banned_starter" not in ignored:
        findings.extend(
            regex_findings("banned_starter", STARTER_PATTERN, text, show_snippets, group=1)
        )
    if "banned_cliche" not in ignored:
        findings.extend(regex_findings("banned_cliche", CLICHE_PATTERN, text, show_snippets))
    if "smart_quotes" not in ignored:
        for match in re.finditer("[" + re.escape(SMART_QUOTES) + "]", text):
            findings.append(finding("smart_quotes", "error", text, match.start(), show_snippets))
    if "assistant_residue" not in ignored:
        findings.extend(
            regex_findings("assistant_residue", RESIDUE_PATTERN, text, show_snippets)
        )
    if "todo_marker" not in ignored:
        findings.extend(regex_findings("todo_marker", TODO_PATTERN, text, show_snippets))
    if "bracket_placeholder" not in ignored:
        findings.extend(
            regex_findings("bracket_placeholder", BRACKET_PLACEHOLDER_PATTERN, text, show_snippets)
        )
    if mode == "correspondence" and "manual_ivo_signature" not in ignored:
        findings.extend(manual_signature_findings(text, show_snippets))

    detector_enabled = asserted_authorship and asserted_non_assessed
    event_count = 0
    suppressed_count = 0
    if detector_enabled:
        events = detector_events(text, ignored)
        event_count = len(events)
        clustered, suppressed_count = clustered_findings(
            text, events, ignored, show_snippets
        )
        findings.extend(clustered)

    deduplicated: dict[tuple[str, int, int], dict[str, Any]] = {}
    for item in findings:
        deduplicated.setdefault((item["code"], item["line"], item["column"]), item)
    findings = sorted(
        deduplicated.values(), key=lambda item: (item["line"], item["column"], item["code"])
    )
    status = "needs_review" if findings else "pass"
    privacy_note = (
        "Bounded source excerpts are included because --show-snippets was set; keep this JSON local."
        if show_snippets
        else "No source excerpts are included. Line/column metadata may reveal text shape; keep this JSON local."
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "status": status,
        "findings_count": len(findings),
        "mode": mode,
        "asserted_authorship": asserted_authorship,
        "asserted_non_assessed": asserted_non_assessed,
        "detector_analysis": {
            "enabled": detector_enabled,
            "events_considered": event_count,
            "solitary_events_suppressed": True,
            "suppressed_event_count": suppressed_count,
        },
        "privacy_note": privacy_note,
        "disclaimer": (
            "Caller attestations are unverified. This local checker does not verify facts, "
            "authorship, originality, academic-policy compliance, or detector outcomes."
        ),
        "findings": findings,
    }


def validate_args(args: argparse.Namespace) -> set[str]:
    if args.assert_authorship != args.assert_non_assessed:
        raise InvocationError(
            "Detector analysis requires both --assert-authorship and --assert-non-assessed."
        )
    if args.mode == "correspondence" and args.assert_authorship:
        raise InvocationError("Detector analysis is not available in correspondence mode.")
    ignored = set(args.ignore_rule)
    unknown = ignored - IGNORABLE_CODES
    if unknown:
        raise InvocationError("Unknown --ignore-rule code: " + ", ".join(sorted(unknown)))
    return ignored


def main(argv: list[str] | None = None) -> int:
    try:
        args = parser().parse_args(argv)
        ignored = validate_args(args)
        text = read_text(args.file)
        payload = analyze(
            text=text,
            mode=args.mode,
            asserted_authorship=args.assert_authorship,
            asserted_non_assessed=args.assert_non_assessed,
            show_snippets=args.show_snippets,
            ignored=ignored,
        )
        emit(payload)
        return 1 if payload["status"] == "needs_review" else 0
    except InvocationError as exc:
        emit(error_payload("invalid_invocation", str(exc)))
        return 2
    except Exception as exc:  # last-resort structured failure contract
        emit(
            error_payload(
                "internal_error",
                f"The checker failed unexpectedly ({exc.__class__.__name__}).",
            )
        )
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
