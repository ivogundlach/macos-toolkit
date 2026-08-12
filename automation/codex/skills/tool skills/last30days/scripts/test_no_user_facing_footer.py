#!/usr/bin/env python3
"""Regression checks that internal engine diagnostics never reach users."""
from __future__ import annotations

import os
import sys
import importlib.util
import tempfile
import re
from pathlib import Path

SCRIPT_DIR = Path(
    os.environ.get("LAST30DAYS_TEST_SCRIPTS_DIR", Path(__file__).resolve().parent)
)
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from lib import html_render, render, schema  # noqa: E402

SPEC = importlib.util.spec_from_file_location("last30days_main", SCRIPT_DIR / "last30days.py")
assert SPEC and SPEC.loader
last30days_main = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(last30days_main)


FORBIDDEN = (
    "All agents reported back",
    "PASS-THROUGH FOOTER",
    "Top voices:",
    "Raw results saved to",
    "I'm now an expert on",
    "I have all the links to",
)

FORBIDDEN_PATTERNS = (
    re.compile(r"(?m)^[├└]─\s"),
    re.compile(r"(?i)\b(?:would you like|want me to|let me know if)\b"),
    re.compile(r"(?i)\braw (?:results?|report) (?:saved|written) (?:to|at)\b"),
    re.compile(r"(?i)\b(?:i am|i'm) now an expert\b"),
)


def sample_report(topic: str) -> schema.Report:
    item = schema.SourceItem(
        item_id="reddit-1",
        source="reddit",
        title="Useful discussion",
        body="A useful community observation.",
        url="https://example.invalid/discussion",
        author="example_user",
        container="example",
        engagement={"score": 42, "comments": 7},
    )
    candidate = schema.Candidate(
        candidate_id=f"{topic.lower()}-candidate",
        item_id=item.item_id,
        source="reddit",
        title=item.title,
        url=item.url,
        snippet=item.body,
        subquery_labels=["main"],
        native_ranks={"reddit": 1},
        local_relevance=1.0,
        freshness=100,
        engagement=42,
        source_quality=1.0,
        rrf_score=1.0,
        sources=["reddit"],
        source_items=[item],
        final_score=1.0,
    )
    cluster = schema.Cluster(
        cluster_id=f"{topic.lower()}-cluster",
        title="Useful finding",
        candidate_ids=[candidate.candidate_id],
        representative_ids=[candidate.candidate_id],
        sources=["reddit"],
        score=1.0,
    )
    return schema.Report(
        topic=topic,
        range_from="2026-07-10",
        range_to="2026-08-09",
        generated_at="2026-08-09T12:00:00Z",
        provider_runtime=schema.ProviderRuntime(
            reasoning_provider="local",
            planner_model="host",
            rerank_model="local",
        ),
        query_plan=schema.QueryPlan(
            intent="general",
            freshness_mode="recent",
            cluster_mode="topic",
            raw_topic=topic,
            subqueries=[],
            source_weights={"reddit": 1.0},
        ),
        clusters=[cluster],
        ranked_candidates=[candidate],
        items_by_source={"reddit": [item]},
        errors_by_source={},
    )


def assert_clean(name: str, output: str) -> None:
    leaked = [marker for marker in FORBIDDEN if marker in output]
    if leaked:
        raise AssertionError(f"{name} leaked user-facing diagnostics: {leaked}")
    pattern_leaks = [pattern.pattern for pattern in FORBIDDEN_PATTERNS if pattern.search(output)]
    if pattern_leaks:
        raise AssertionError(f"{name} leaked reworded diagnostics: {pattern_leaks}")


def assert_useful(name: str, output: str) -> None:
    if "last30days v" not in output:
        raise AssertionError(f"{name} lost the Last30Days badge")
    if "example.invalid/discussion" not in output:
        raise AssertionError(f"{name} lost readable citation evidence")


def main() -> int:
    first = sample_report("Alpha")
    second = sample_report("Beta")
    synthesis = (
        "What I learned:\n\n**Useful finding** - The evidence supports it "
        "per [the discussion](https://example.invalid/discussion)."
    )

    outputs = {
        "compact": render.render_compact(first, save_path="/hidden/raw.md"),
        "html": html_render.render_html(
            first, synthesis_md=synthesis, save_path="/hidden/raw.md"
        ),
        "comparison_html": html_render.render_html_comparison(
            [("Alpha", first), ("Beta", second)],
            synthesis_md=(
                "## Quick Verdict\n\nAlpha leads per "
                "[the discussion](https://example.invalid/discussion)."
            ),
            save_path="/hidden/raw.md",
        ),
        "comparison_compact": render.render_comparison_multi(
            [("Alpha", first), ("Beta", second)], save_path="/hidden/raw.md"
        ),
    }
    mode_failures: list[str] = []
    for name, output in outputs.items():
        try:
            assert_clean(name, output)
            assert_useful(name, output)
        except AssertionError as exc:
            mode_failures.append(str(exc))

    empty = sample_report("Empty")
    empty.clusters = []
    empty.ranked_candidates = []
    empty.items_by_source = {}
    empty.warnings = ["Evidence validation returned no usable items."]
    empty_outputs = {
        "empty_compact": render.render_compact(empty, save_path="/hidden/raw.md"),
        "empty_html": html_render.render_html(
            empty, synthesis_md="What I learned:\n\nNo supported finding.", save_path="/hidden/raw.md"
        ),
        "empty_comparison_compact": render.render_comparison_multi(
            [("Empty", empty), ("Also Empty", empty)], save_path="/hidden/raw.md"
        ),
        "empty_comparison_html": html_render.render_html_comparison(
            [("Empty", empty), ("Also Empty", empty)],
            synthesis_md="## Quick Verdict\n\nNo supported finding.",
            save_path="/hidden/raw.md",
        ),
    }
    for name, output in empty_outputs.items():
        try:
            assert_clean(name, output)
        except AssertionError as exc:
            mode_failures.append(str(exc))

    auxiliary_outputs = {
        "context": render.render_context(first),
        "comparison_context": render.render_comparison_multi_context(
            [("Alpha", first), ("Beta", second)]
        ),
        "brief": render.render_brief(first),
        "full": render.render_full(first),
    }
    for name, output in auxiliary_outputs.items():
        try:
            assert_clean(name, output)
        except AssertionError as exc:
            mode_failures.append(str(exc))

    if mode_failures:
        raise AssertionError("mode failures:\n- " + "\n- ".join(mode_failures))

    skill_root = SCRIPT_DIR.parent
    instruction_files = [
        skill_root / "SKILL.md",
        skill_root / "assets/templates/general.md",
        skill_root / "assets/templates/comparison.md",
        skill_root / "references/voice-contract.md",
        skill_root / "references/advanced-modes.md",
        skill_root / "references/save-html-brief.md",
        skill_root / "references/setup-and-runtime.md",
    ]
    retired_directives = (
        "✅ All agents reported back!",
        "{engine footer copied verbatim}",
        "I'm now an expert on {TOPIC}",
        "I have all the links to the {N}",
        "Every invitation MUST",
        "Engine footer pass-through",
    )
    for path in instruction_files:
        text = path.read_text(encoding="utf-8")
        leaked = [phrase for phrase in retired_directives if phrase in text]
        if leaked:
            raise AssertionError(f"{path.name} still teaches retired output: {leaked}")

    skill_text = (skill_root / "SKILL.md").read_text(encoding="utf-8")
    if "keep the raw report hidden unless Ivo explicitly asks for it" not in skill_text:
        raise AssertionError("SKILL.md lost the explicit-request-only raw-report rule")
    regression_text = (skill_root / "references/regression-history.md").read_text(encoding="utf-8")
    if "INTERNAL FOOTER RETIRED 2026-08-09" not in regression_text:
        raise AssertionError("regression history no longer labels the old footer as retired")

    with tempfile.TemporaryDirectory(prefix="last30days-raw-proof-") as temp_dir:
        raw_path = last30days_main.save_output(first, "compact", temp_dir)
        if not raw_path.is_file() or "## Ranked Evidence Clusters" not in raw_path.read_text(encoding="utf-8"):
            raise AssertionError("hidden raw report is no longer saved for explicit retrieval")

    print(
        f"ok: {len(outputs)} user-facing render modes, {len(empty_outputs)} "
        f"empty/degraded variants, and {len(auxiliary_outputs)} auxiliary text modes "
        "contain no internal footer; badge, citations, instruction guards, retired-history "
        "labeling, explicit-request gating, and hidden raw-report retrieval are preserved"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
