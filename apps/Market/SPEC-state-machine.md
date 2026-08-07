# State-Machine Spec — recommendations tracks (v2, sentiment analyst)

Status: APPROVED by Ivo 2026-07-01 (supersedes v1 mention-counting arithmetic).
Decision: the LLM's conviction score is AUTHORITATIVE; code enforces guardrails, not scoring
arithmetic. Entry is IMMEDIATE (one debrief above threshold). All constants live in
`config.json` (`sentiment` block + per-track `entry_conviction`); changes are logged as diffs
in the run manifest. v1 track keys (`min_clusters`, `independence_required`, `min_spread_days`,
`rank12_strong_overrides`, `window_trading_days`) are deprecated and unused.

## Inputs per debrief run

- **Evidence clusters** from validated codex output. Each cluster: ticker, direction
  (bullish/bearish), **model conviction 0–100** (the model's deep-sentiment judgment of the
  thesis + the speakers' own conviction), thesis_type (catalyst/valuation/technical/momentum/
  meme/other), horizon, justification prose, per-speaker analyses with **verbatim quotes**,
  proposed track, cited event_ids.
- **Guardrails applied upstream in `synthesize.validate` (code, not model):**
  - *Quote verification*: every speaker analysis must contain ≥1 quote (≥12 normalized chars)
    that literally appears in the cited event's text. Unverified speakers are dropped; a
    cluster with no verified speaker is dropped entirely — hallucinated evidence never
    reaches state.
  - *Rank caps* (`sentiment.rank_conviction_caps`): capped_conviction =
    min(model_conviction, cap[best_rank]). Defaults: 1→100, 2→95, 3→80, 4→75, 5→60.
    Only the capped value may feed state.
  - Ticker regex + denylist, event_id existence, enum coercion, bound clamps.
- **Best rank** of a cluster = best (lowest) trust rank among its cited events.
- **Regime score** 0–100 from `market_regime.py` (bearish < 40 ≤ neutral ≤ 60 < bullish).

## Scoring semantics

```
entry:      capped_conviction >= track.entry_conviction  (default 60; immediate, one debrief)
            bearish regime (<40): threshold ×= regime.bearish_entry_threshold_multiplier (1.5)
            entry conviction = capped_conviction (cap 95)
reinforce:  conviction' = (1-α)·conviction + α·target      target = strongest bullish capped
bear pull:  conviction' = max(0, (1-α)·conviction − α·pull) pull = strongest bearish capped
            (bearish evidence below the T6 bar drags conviction down proportionally)
decay:      conviction' = conviction · (1 − decay_pct_per_trading_day/100)   (no new signal)
α = sentiment.ema_alpha (default 0.5) — smoothing so one hyped debrief cannot spike state
"strongest" is deterministic: max by (capped_conviction, −best_rank, origin_key)
```

## Per-track parameters (config)

| | Growth | Value | Dividends |
|---|---|---|---|
| entry_conviction | 60 | 60 | 60 |
| Decay (no new signal) | −5%/trading day | −5%/trading day | −2%/trading day |
| Exit threshold | conviction < 20 | < 20 | < 20 |

## Transition table

| # | Condition | Action |
|---|---|---|
| T1 | Strongest bullish capped_conviction ≥ threshold AND regime gate AND coverage fresh | ENTER immediately: conviction = capped (cap 95); track pinned; audit carries thesis_type, horizon, justification, n_speakers |
| T2 | Met base entry_conviction BUT bearish regime raised the bar | No entry; audited with conviction + raised threshold |
| T3 | Bullish cluster on held ticker | EMA toward strongest capped target, cap 95 |
| T3 (bearish) | Bearish cluster below the T6 bar on held ticker | conviction pulled down: (1−α)·old − α·pull, floor 0 |
| T4 | No signal on held ticker | decay per track table |
| T5 | conviction < 20 | EXIT, reason "decayed" |
| T6 | Bearish cluster, rank ≤ 2, capped_conviction ≥ sentiment.exit_bearish_conviction (75) | EXIT immediately, reason "rank-override" |
| T7 | Bullish + bearish same run, best-rank gap ≥ 2 | higher rank wins (applied as T3/T6); audited |
| T8 | Same situation, rank gap < 2 (held OR candidate) | ABSTAIN: held ticker flagged "conflict"; candidate gets no entry |
| T9 | Track's required coverage stale (x_tier1 > 2 days old or regime missing) | FREEZE new entries (T1/T2 disabled); T3–T6 keep running; banner |
| T10 | Ticker unresolved by alias table | QUARANTINE: never enters tracks; listed in health panel |

Every transition writes an audit row: evidence IDs, conviction math inputs, model justification
(T1/T6), prompt+model version, config hash.

## Legacy replay (recompute)

Pre-v3 signals carry only `strength`; recompute maps them deterministically:
strong→70, moderate→50, weak→30, then rank-capped (`state_machine.legacy_conviction`).
Consequence: legacy moderate/weak mention-clusters no longer produce entries — by design.

## Pinning & overrides

Model proposes a track per cluster; majority proposal wins; the first accepted ENTER pins the
ticker. Re-classification only via override (`appctl override`). Manual overrides (pin,
force_exit, manual_add, resolve_conflict) keep precedence over model state through every
recompute, unchanged from v1.
