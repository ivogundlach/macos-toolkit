# ~/Projects/Market data contracts (schema_version 1)

## Canonical store

`state/market.sqlite` is the single transactional source of truth. Dated JSONL files under
`inbox/<source>/` are derived exports for human inspection, never read back by the pipeline.

### events

| column | meaning |
|---|---|
| event_id | sha256("<source>:<native_id>") — tweet ID, video ID, Gmail message ID, Discord message ID |
| schema_version | 1 |
| ts | original content timestamp, UTC ISO-8601 |
| ingested_at | adapter run timestamp, UTC ISO-8601 |
| session_date | NYSE session the event belongs to (America/New_York calendar date at `ts`) |
| source | discord, tradingview, x_tier1, youtube, x_tier2, regime |
| rank | trust rank from config (1 best, 5 lowest; 0 = market data) |
| author | handle / channel / alert name |
| type | post, video, alert, regime_snapshot |
| text | sanitized plain text, capped at limits.max_event_text_chars |
| tickers | JSON array of cashtags found ($X). Deep extraction happens in synthesis |
| urls | JSON array, https-only, exact-host allowlisted |
| engagement | JSON object (likes, retweets, views, ...) |
| raw_ref | local file path of the raw payload. Never a URL, never a secret |

Insertion is `INSERT OR IGNORE` on event_id: replaying any adapter is always safe.

### regime

One row per session_date: vix, vix_trend5d, fear_greed, put_call, oi_note, score (0–100,
50 = neutral, higher = bullish), confidence (full/partial/stale), formula_version, raw JSON.
Computed deterministically in `adapters/market_regime.py` — never by the LLM.

### runs (populated from step 7 on)

run_id, started_at, committed_at, kind, watermark, manifest JSON (config hash, model+prompt
version, content hash). Side effects (dashboard rename, email send) are retryable projections
recorded against a committed run; email is at-most-once via persisted Message-ID.

## Drop-in rule

A new source = one adapter writing events through `pipeline/store.py` + a config entry
(rank, enabled) + a fixture test. Synthesis, ranking, dashboard, email read only the store.
