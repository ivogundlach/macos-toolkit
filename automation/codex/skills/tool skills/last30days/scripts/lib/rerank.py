"""Deterministic relevance ranking and low-confidence demotion."""

from __future__ import annotations

import re

from . import query, schema, signals


# Penalty applied when a candidate does not mention the primary entity
# from the topic in its title or snippet. Picked empirically: a typical
# score spread in the shortlist is 30-70, so 25 points reliably pushes
# an off-topic candidate below on-topic ones without fully zeroing out
# marginal matches. See 2026-04-19 Hermes Agent Use Cases failure: a
# Nate Herk "Managed Agents" video scored 51 / ranked #2 with zero
# Hermes content.
ENTITY_MISS_PENALTY = 25.0

# Small additive credit for a post authored by one of the run's resolved
# handles (see rerank_candidates / _fallback_tuple). Deliberately small: the
# goal is to stop *burying* first-party posts, not to auto-win the ranking on
# authorship alone. A strong on-topic third-party item (high local relevance)
# still outranks a thin first-party one; this only lifts first-party off the
# neutral floor so it survives into the visible band.
FIRST_PARTY_AUTHOR_CREDIT = 5.0

# Engagement rescue: a high-engagement X post that is on-topic (entity-grounded
# or first-party) cannot be fully zeroed by the other penalties. The floor is a
# function of the post's engagement percentile *within the run's X pool* (so it
# adapts to each topic's engagement scale) and is bounded by RESCUE_FLOOR_MAX.
# Critically it is NEVER applied to entity-miss-demoted (off-topic collision)
# posts, so viral name-collision noise (Lanzhou clips, namesakes) stays buried.
RESCUE_FLOOR_MAX = 40.0

# Interaction signal: a first-party post directed AT another account (a reply /
# leading @mention) carries relational signal — who the subject is personally
# engaging — that no keyword or like-count surfaces. It is floated to a minimum
# final_score so it survives into the visible band regardless of engagement,
# and tagged (candidate.metadata["interaction_targets"]) so the synthesizing
# model reads it as relational, not noise. Floor (not additive) so it composes
# with the engagement rescue without unbounded stacking.
INTERACTION_FLOOR = 35.0

# First-party survival floor. A post authored by a resolved handle must clear
# the zero band. A post rarely names its own author, so ordinary entity-grounding
# would otherwise bury plain low-engagement first-party posts. This floor is a
# deterministic backstop; it is modest
# (well below strong on-topic evidence at 50+) so authorship buys visibility,
# not a win.
FIRST_PARTY_FLOOR = 25.0

# Intent modifiers to strip before extracting the primary entity so that,
# for example, "Hermes Agent use cases" yields primary_entity="hermes agent"
# rather than "hermes agent use cases". Kept in sync with
# planner._INTENT_MODIFIER_PATTERNS.
_INTENT_MODIFIER_RE = re.compile(
    r"\b("
    r"use cases|use case|workflows|workflow|"
    r"examples|example|tutorial|tutorials|"
    r"review|reviews|comparison|applications|"
    r"in practice|production use|production|"
    r"how i use"
    r")\b",
    re.IGNORECASE,
)



def rerank_candidates(
    *,
    topic: str,
    plan: schema.QueryPlan,
    candidates: list[schema.Candidate],
    shortlist_size: int,
    resolved_handles: set[str] | None = None,
) -> list[schema.Candidate]:
    """Rerank the fused shortlist, demoting candidates the reranker scored as irrelevant.

    ``resolved_handles`` is the normalized (``@``-stripped, lowercased) set of
    handles the run resolved for the topic (``--x-handle``, ``--x-related``, and
    the GitHub user). A candidate authored by one of these is first-party: it is
    exempted from the entity-miss demotion in ``_fallback_tuple`` (a post almost
    never repeats its own author's name, so the body-text grounding check would
    otherwise bury the subject's own highest-signal posts).
    """
    handles = resolved_handles or set()
    shortlisted = candidates[:shortlist_size]
    primary_entity = _primary_entity(topic)
    _apply_fallback_scores(shortlisted, primary_entity=primary_entity, resolved_handles=handles)

    if len(candidates) > shortlist_size:
        tail = candidates[shortlist_size:]
        _apply_fallback_scores(tail, primary_entity=primary_entity, resolved_handles=handles)

    _apply_first_party_floor(candidates, resolved_handles=handles)
    _apply_engagement_rescue(candidates, primary_entity=primary_entity, resolved_handles=handles)
    _apply_interaction_signal(candidates, resolved_handles=handles)

    return sorted(
        candidates,
        key=lambda candidate: (
            -candidate.final_score,
            -(candidate.engagement or -1),
            min(candidate.native_ranks.values(), default=999),
            candidate.title,
        ),
    )




def _apply_fallback_scores(
    candidates: list[schema.Candidate], *, primary_entity: str = "", resolved_handles: set[str] | None = None
) -> None:
    handles = resolved_handles or set()
    for candidate in candidates:
        rerank_score, reason = _fallback_tuple(candidate, primary_entity=primary_entity, resolved_handles=handles)
        candidate.rerank_score = rerank_score
        candidate.explanation = reason
        candidate.final_score = _final_score(candidate)


def _candidate_author_handle(candidate: schema.Candidate) -> str:
    """Representative normalized author handle for a candidate, or '' if none.

    Reads ``SourceItem.author`` (set from the X ``author_handle`` in
    normalize._normalize_x, already ``@``-stripped) on the first authored
    source item, falling back to that item's ``metadata.author_handle``.
    Normalized ``@``-stripped + lowercased to match the resolved-handle set.
    """
    for item in candidate.source_items:
        raw = item.author or (item.metadata or {}).get("author_handle") or ""
        handle = str(raw).lstrip("@").strip().lower()
        if handle:
            return handle
    return ""


def _is_first_party(candidate: schema.Candidate, resolved_handles: set[str]) -> bool:
    """True when the candidate is authored by one of the run's resolved handles."""
    if not resolved_handles:
        return False
    return _candidate_author_handle(candidate) in resolved_handles


def _is_x_candidate(candidate: schema.Candidate) -> bool:
    """True when the candidate originates from X (top-level or any source item)."""
    if candidate.source == "x":
        return True
    return any(getattr(item, "source", None) == "x" for item in candidate.source_items)


def _candidate_engagement(candidate: schema.Candidate) -> float:
    return candidate.engagement if candidate.engagement is not None else 0.0


def _is_entity_grounded(candidate: schema.Candidate, primary_entity: str) -> bool:
    """Whether the candidate plausibly mentions the primary entity in its text.

    Mirrors the grounding gate used for the entity-miss demotion: no
    primary_entity means everything is grounded; otherwise the candidate must
    have text that contains the entity's head token.
    """
    if not primary_entity:
        return True
    haystack = _candidate_haystack(candidate)
    return bool(haystack.strip()) and _entity_grounded(haystack, primary_entity)


def _rescue_floor(percentile: float) -> float:
    """Engagement rescue floor: 0 at/below the median, scaling linearly to
    RESCUE_FLOOR_MAX at the top of the X pool."""
    if percentile <= 0.5:
        return 0.0
    return ((percentile - 0.5) / 0.5) * RESCUE_FLOOR_MAX


def _candidate_mentioned_handles(candidate: schema.Candidate) -> set[str]:
    """Normalized handles the candidate's post is directed at (leading @mentions
    parsed at ingest into source-item metadata)."""
    handles: set[str] = set()
    for item in candidate.source_items:
        for h in (item.metadata or {}).get("mentioned_handles") or []:
            norm = str(h).lstrip("@").strip().lower()
            if norm:
                handles.add(norm)
    return handles


def _interaction_targets(candidate: schema.Candidate, resolved_handles: set[str]) -> set[str]:
    """Accounts a first-party post is directed at, excluding the subject's own
    handles. Empty unless the candidate is first-party AND addresses someone
    other than the subject."""
    if not _is_first_party(candidate, resolved_handles):
        return set()
    return _candidate_mentioned_handles(candidate) - resolved_handles


def _apply_interaction_signal(
    candidates: list[schema.Candidate], *, resolved_handles: set[str]
) -> None:
    """Float and tag first-party posts directed at another account. The relational
    tell (the subject personally engaging someone) is invisible to keyword and
    engagement scoring, so these are floored into the visible band and tagged so
    synthesis reads them as signal."""
    if not resolved_handles:
        return
    for c in candidates:
        targets = _interaction_targets(c, resolved_handles)
        if not targets:
            continue
        c.metadata = {**(c.metadata or {}), "interaction_targets": sorted(targets)}
        if c.final_score < INTERACTION_FLOOR:
            c.final_score = INTERACTION_FLOOR


def _apply_first_party_floor(
    candidates: list[schema.Candidate], *, resolved_handles: set[str]
) -> None:
    """Floor every first-party post above the zero band.

    A first-party post rarely names its own author, so grounding alone can
    re-bury it. Floor only lifts; it never lowers a stronger local score.
    """
    if not resolved_handles:
        return
    for c in candidates:
        if _is_first_party(c, resolved_handles) and c.final_score < FIRST_PARTY_FLOOR:
            c.final_score = FIRST_PARTY_FLOOR


def _apply_engagement_rescue(
    candidates: list[schema.Candidate], *, primary_entity: str, resolved_handles: set[str]
) -> None:
    """Floor final_score for high-engagement X posts that are first-party or
    entity-grounded, so a viral on-topic post can't sit at ~0. Off-topic
    (entity-miss) collision posts are excluded, preserving noise suppression.
    """
    x_cands = [c for c in candidates if _is_x_candidate(c)]
    if len(x_cands) < 2:
        return
    engagements = sorted(_candidate_engagement(c) for c in x_cands)
    n = len(engagements)
    for c in x_cands:
        if not (_is_first_party(c, resolved_handles) or _is_entity_grounded(c, primary_entity)):
            continue
        e = _candidate_engagement(c)
        # Percentile rank in [0, 1]: fraction of the X pool strictly below e.
        percentile = sum(1 for v in engagements if v < e) / (n - 1)
        floor = _rescue_floor(percentile)
        if floor > c.final_score:
            c.final_score = floor


def _candidate_haystack(candidate: schema.Candidate) -> str:
    """Build the lowercase text blob against which entity-grounding is checked.

    Expanded 2026-04-19 to include transcript snippets, transcript highlights,
    and top-comment text. The prior `title + snippet` check missed YouTube
    videos whose entity mentions live in transcript content and Reddit posts
    whose mentions are in top comments. Now checks all text surfaces a human
    would see.
    """
    parts: list[str] = [candidate.title or "", candidate.snippet or ""]
    metadata = candidate.metadata or {}

    transcript_snippet = metadata.get("transcript_snippet") or ""
    if isinstance(transcript_snippet, str):
        parts.append(transcript_snippet)

    for hl in metadata.get("transcript_highlights") or []:
        if isinstance(hl, str):
            parts.append(hl)

    for tc in metadata.get("top_comments") or []:
        if isinstance(tc, dict):
            parts.append(str(tc.get("excerpt", "") or tc.get("text", "") or ""))
        elif isinstance(tc, str):
            parts.append(tc)

    for insight in metadata.get("comment_insights") or []:
        if isinstance(insight, str):
            parts.append(insight)

    return " ".join(parts).lower()


def _entity_grounded(haystack: str, primary_entity: str) -> bool:
    """True if the candidate text plausibly mentions the primary entity.

    Grounds on the HEAD token of the primary entity (the brand / proper-noun
    core), not the full multi-word phrase. Trailing tokens are usually category
    descriptors the user/planner appended for search ("Stripe payments"), not
    part of the entity, so requiring the whole phrase over-demotes on-entity
    items that omit the descriptor. Items that never name the brand at all still
    miss the head token and stay demoted.

    Trade-off: a proper noun with a generic head ("New York Times" -> "new")
    under-demotes rather than over-demotes - the safe direction, since the
    observed harm was burying real high-engagement signal. Substring (not
    word-boundary) matching is likewise deliberate: it catches plurals and
    compounds ("stripes"), and vacuous matches from very short heads ("X",
    "Go") merely disable the penalty rather than burying good items.
    """
    haystack = haystack.lower()
    tokens = primary_entity.lower().split()
    if not tokens:
        return True
    return tokens[0] in haystack


def _fallback_tuple(
    candidate: schema.Candidate, *, primary_entity: str = "", resolved_handles: set[str] | None = None
) -> tuple[float, str]:
    score = (
        (candidate.local_relevance * 100.0 * 0.7)
        + (candidate.freshness * 0.2)
        + (candidate.source_quality * 100.0 * 0.1)
    )
    reason = "fallback-local-score"
    # First-party authorship grounding: a post authored by one of the run's
    # resolved handles is first-class evidence about the subject and is exempt
    # from the entity-miss demotion below. Nobody repeats their own name in
    # their own post, so the body-text grounding check would otherwise bury the
    # subject's own highest-signal posts (the single richest vein on X for a
    # person topic). Because the reason string carries no "entity-miss" marker,
    # _final_score's secondary penalty (which greps for it) is also skipped.
    # A small bounded credit lifts a first-party post just off neutral without
    # letting authorship alone outrank a genuinely strong on-topic third party.
    if resolved_handles and _is_first_party(candidate, resolved_handles):
        score += FIRST_PARTY_AUTHOR_CREDIT
        return max(0.0, min(100.0, score)), "fallback-local-score (first-party authorship)"
    # Entity-grounding demotion: subtract ENTITY_MISS_PENALTY when the candidate
    # never mentions the primary entity's head token, across all text surfaces
    # (title, snippet, transcript, transcript highlights, top comments,
    # insights). Skip for candidates with NO text anywhere (e.g. image-only
    # TikToks) so thin-text sources aren't penalized unfairly. See
    # _entity_grounded for why grounding keys on the head token, not the phrase.
    if primary_entity:
        haystack = _candidate_haystack(candidate)
        if haystack.strip() and not _entity_grounded(haystack, primary_entity):
            score -= ENTITY_MISS_PENALTY
            reason = "fallback-local-score (entity-miss demotion)"
    return max(0.0, min(100.0, score)), reason


def _primary_entity(topic: str) -> str:
    """Extract the primary entity from the topic for grounding checks.

    Strips intent-modifier suffixes (see planner._INTENT_MODIFIER_PATTERNS),
    trims trailing punctuation, collapses whitespace. Returns the empty
    string for topics that are all intent modifier with no entity, so
    callers can skip the grounding check.
    """
    stripped = _INTENT_MODIFIER_RE.sub(" ", topic)
    # Also collapse multiple spaces and strip punctuation.
    stripped = re.sub(r"\s+", " ", stripped).strip(" \t\r\n?.,:;!")
    return stripped


#: Secondary entity-miss penalty applied directly to final_score (not just
#: rerank_score). The -25 on rerank_score composes to only -15 on final_score
#: via the 0.60 weight, which engagement bonus partially offsets on
#: high-view YouTube items. This secondary penalty lands the full weight on
#: the composite signal the cluster-scoring layer consumes. 2026-04-19
#: Nate Herk "Managed Agents" video ranked at cluster #2 with score 51
#: despite the rerank_score demotion because engagement + freshness drowned
#: the dilute penalty. This backstop makes the demotion actually decisive.
ENTITY_MISS_FINAL_PENALTY = 20.0


def _final_score(candidate: schema.Candidate) -> float:
    normalized_rrf = _normalized_rrf(candidate.rrf_score)
    rerank_score = candidate.rerank_score or 0.0
    # Engagement bonus: high-engagement items (viral TikToks, popular YouTube videos)
    # get a boost so they aren't buried by lower-engagement but text-relevant items.
    # Engagement is log1p-normalized (0-100 range via signals.py), so a 2.5M-view
    # TikTok scores ~15 and a 1500-view one scores ~7. The 0.05 weight gives a
    # meaningful but not dominant boost.
    engagement_val = candidate.engagement if candidate.engagement is not None else 0.0
    base = (
        0.60 * rerank_score
        + 0.20 * normalized_rrf
        + 0.10 * candidate.freshness
        + 0.05 * (candidate.source_quality * 100.0)
        + 0.05 * min(engagement_val * 6.0, 100.0)
    )
    if candidate.rerank_score is not None and candidate.rerank_score < 20.0:
        base *= 0.3
    # Secondary entity-grounding penalty: when the fallback path flagged
    # entity-miss via candidate.explanation, apply an additional penalty
    # at final_score level so engagement signal can't mask the demotion.
    if candidate.explanation and "entity-miss" in candidate.explanation:
        base = max(0.0, base - ENTITY_MISS_FINAL_PENALTY)
    return base




def score_fun(
    *,
    topic: str,
    candidates: list[schema.Candidate],
    max_candidates: int = 60,
) -> None:
    """Apply deterministic humor/shareability signals."""
    del topic
    pool = candidates[:max_candidates]
    _apply_fun_fallback(pool)




def _extract_comment_text(candidate: schema.Candidate) -> str:
    parts = []
    for item in candidate.source_items:
        for comment in item.metadata.get("top_comments", [])[:3]:
            body = comment.get("body", "") if isinstance(comment, dict) else str(comment)
            if body:
                parts.append(body[:150])
        for insight in item.metadata.get("comment_insights", [])[:2]:
            if insight:
                parts.append(str(insight)[:150])
    return " | ".join(parts) if parts else ""


def _apply_fun_fallback(candidates: list[schema.Candidate]) -> None:
    for c in candidates:
        _apply_single_fun_fallback(c)


def _apply_single_fun_fallback(candidate: schema.Candidate) -> None:
    text = candidate.title + " " + (candidate.snippet or "") + " " + _extract_comment_text(candidate)
    text_len = len(text.strip())
    shortness = max(0, (200 - text_len) / 200) * 30
    # Reward a highly-upvoted TOP COMMENT (the crowd-certified line), normalized
    # per platform, rather than the post's overall engagement.
    vote_bonus = signals.top_comment_vote_signal(candidate) * 40.0
    markers = ["lol", "lmao", "dead", "hilarious", "funny", "bruh", "ratio", "nah", "bro", "ain't no way", "i'm crying", "rent free"]
    marker_bonus = 10 if any(m in text.lower() for m in markers) else 0
    candidate.fun_score = max(0.0, min(100.0, shortness + vote_bonus + marker_bonus))
    candidate.fun_explanation = "heuristic-fallback"


def _normalized_rrf(rrf_score: float) -> float:
    # Empirical ceiling for normalized RRF scores at the pool sizes we use.
    # Max single-stream RRF at rank 1 is 1/(K+1) ~ 0.016; multi-stream
    # accumulation reaches ~0.08.
    return max(0.0, min(100.0, (rrf_score / 0.08) * 100.0))
