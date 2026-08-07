# CONTRACTS.md — frozen interfaces for the Market app (Phase 0)

Status: FROZEN 2026-06-14. Agents A/B/C implement against this; do not invent schema or protocol.
Any change requires updating this file in the main session first.

AMENDED 2026-07-01 (schema v3, sentiment analyst — approved by Ivo): `signals` gains additive
columns `model_conviction REAL, capped_conviction REAL, thesis_type TEXT, horizon TEXT,
justification TEXT, speakers TEXT(JSON)`. meta: schema_version=3, min_supported=2,
max_supported=3 (v3 is additive; v2 readers — including the installed Swift app — stay valid).
Scoring semantics moved to SPEC-state-machine.md v2: LLM conviction authoritative, code
guardrails = quote verification + rank caps (`sentiment.rank_conviction_caps`) + EMA smoothing
(`sentiment.ema_alpha`) + per-track `entry_conviction`. `strength` remains populated as a
derived display bucket (capped ≥70 strong, ≥40 moderate, else weak).

AMENDED 2026-07-01 #2 (schema v4, app-delivered notifications — Ivo: "replace everything"):
EMAIL DELIVERY IS RETIRED. `send_email.py`/`build_dashboard.py` have no pipeline callers.
`runs_debrief` gains `debrief_json TEXT` + `run_id TEXT` (full debrief persisted; the app is
the sole debrief surface, rendered on Overview). meta: schema_version=4, max_supported=4.
New appctl commands (mutating, no generation bump): `notify-claim` `{limit?}` → claims
pending outbox rows (pending→delivering, 120s lease) and returns them; `notify-ack`
`{ids: []}` → delivering→delivered. Market.app polls notify-claim every 45s, posts native
UNUserNotificationCenter notifications (outbox id = notification id, so no duplicate
banners), then acks. Rows are claimed only after the notification permission is granted;
crash between claim and ack self-heals via lease expiry. Pipeline enqueues these kinds:
debrief_ready, debrief_degraded, track_entry, track_exit, run_failed, debrief_missed
(watchdog). osascript banners remain ONLY as the immediate last-resort for pipeline
failure/watchdog while the app is closed.

Conventions: all money/quantity as **decimal strings** (locale-independent, `.`-decimal, no
thousands sep). Timestamps UTC ISO-8601. All paths absolute. Python (`appctl`) owns all writes and
all arithmetic; Swift only reads + renders + calls appctl.

---

## 1. appctl JSON protocol

Invocation (from Swift, no shell): 
`/Users/YOUR_USERNAME/Projects/Market/venv/bin/python /Users/YOUR_USERNAME/Projects/Market/pipeline/appctl.py <cmd> --json '<args>'`

stdin/args: `<args>` is a JSON object. stdout: exactly one JSON object:

```json
{ "status": "ok" | "error",
  "code": "OK|VALIDATION|LOCK_BUSY|MIGRATION|NOT_FOUND|CONFLICT|INTERNAL",
  "generation": 1234,            // monotonic; bumps on every committed write/recompute
  "config_version": 7,           // applied config version after this command
  "run_id": "…|null",            // last scheduled run id (context only)
  "message": "human text",       // on error
  "data": { … } }                // command-specific payload on ok
```

Rules: appctl is the SOLE writer. Every mutating command: acquire flock RunLock (non-blocking;
return `LOCK_BUSY` if held) → validate → single SQLite transaction → (config cmds: stage file,
recompute, promote-on-success, atomic-replace config.json, archive prior) → bump `generation` →
commit. Reads may run lock-free (WAL). No partial writes.

Commands (cmd → args → data):
- `get-state` → `{}` → `{regime, tracks[], signals_today[], diff[], health, generation, config}`
- `get-ticker` → `{ticker}` → `{events[], signals[], conviction_history[], transitions[], override?}`
- `set-config` → `{path: "rank_weights.5", value: 0.2}` (or `{patch:{…}}`) → recomputes, returns `{changed, config_version}`
- `recompute` → `{}` → `{generation, tracks[]}` (idempotent; see §3)
- `override` → `{op:"pin|unpin|force_exit|manual_add|resolve_conflict", ticker, track?, note?}` → `{override}`
- `position-set` / `position-replace` / `position-delete` → position object (§2) / position object with `{id}` / `{id}` → `{position}`
- `watchlist-set` / `watchlist-delete` → watchlist object / `{id}` → `{watchlist}`
- `denylist-add` / `denylist-remove` → `{ticker}` → recomputes
- `alias-set` / `alias-delete` → `{alias, canonical}` / `{alias}` → recomputes
- `health` → `{}` → `{adapters[], last_runs[], lock, schema_version}`

Recompute triggers (per grill): set-config, override, denylist-*, alias-* → recompute.
position/watchlist/note edits → persist only, NO recompute.

Command-state model (Swift UI): each call is queued→running→succeeded|failed; UI shows state +
`message`/stderr + `generation`. Calls run off-main-thread with a timeout (default 30s).

---

## 2. SQLite schema v2

Existing (keep): `events, regime, runs, signals, tracks, transitions, runs_debrief`.
`transitions` rows written by SCHEDULED runs are IMMUTABLE audit history — recompute never edits them.

New tables:

```sql
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
-- meta: schema_version=2, min_supported=2, max_supported=2, generation=<int>

CREATE TABLE IF NOT EXISTS derived_state (   -- app-recompute output; safe to wipe+rebuild
  ticker TEXT PRIMARY KEY, track TEXT, status TEXT, conviction REAL,
  entered_at TEXT, last_signal_at TEXT, source TEXT,  -- source: 'model'|'override'
  config_version INTEGER, generation INTEGER);

CREATE TABLE IF NOT EXISTS overrides (       -- survive recompute; precedence > model
  id INTEGER PRIMARY KEY AUTOINCREMENT, ticker TEXT NOT NULL,
  op TEXT NOT NULL, track TEXT, note TEXT,
  created_at TEXT NOT NULL, tombstoned_at TEXT,         -- soft-delete
  UNIQUE(ticker, op, track) ON CONFLICT REPLACE);

CREATE TABLE IF NOT EXISTS positions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, symbol TEXT NOT NULL,
  quantity TEXT NOT NULL, cost_basis TEXT, currency TEXT NOT NULL DEFAULT 'USD',
  account TEXT NOT NULL DEFAULT '', provenance TEXT NOT NULL DEFAULT 'manual',  -- manual|scrape
  opened_at TEXT, updated_at TEXT NOT NULL,
  UNIQUE(symbol, account, provenance));

CREATE TABLE IF NOT EXISTS watchlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL, -- candidate|holding
  tickers TEXT NOT NULL DEFAULT '[]', provenance TEXT NOT NULL DEFAULT 'manual',
  scraped_at TEXT, stale INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
  UNIQUE(name, provenance));

CREATE TABLE IF NOT EXISTS conviction_history (  -- appended ONLY by scheduled runs
  ticker TEXT NOT NULL, run_id TEXT NOT NULL, session_date TEXT NOT NULL,
  track TEXT, conviction REAL, PRIMARY KEY (ticker, run_id));

CREATE TABLE IF NOT EXISTS notifications (   -- transactional outbox
  id TEXT PRIMARY KEY,                       -- deterministic: sha256(kind+ticker+run_id)
  kind TEXT NOT NULL, ticker TEXT, run_id TEXT, body TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',     -- pending|delivering|delivered
  created_at TEXT NOT NULL, delivered_at TEXT, lease_until TEXT);

CREATE INDEX IF NOT EXISTS idx_ch_ticker ON conviction_history(ticker, session_date);
CREATE INDEX IF NOT EXISTS idx_overrides_ticker ON overrides(ticker) WHERE tombstoned_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notif_state ON notifications(state);
```

Retention (pruned by appctl/run): conviction_history 2y, transitions 1y, notifications delivered 90d,
config archives keep 50.

---

## 3. Recompute (idempotent)

`recompute` = pure function of (current `signals` + current `config` + non-tombstoned `overrides`):
1. one transaction; read all signals + config + overrides.
2. replay through `state_machine` (existing engine) to compute current tracks.
3. apply overrides (precedence > model): pin track, force_exit, manual_add, resolve_conflict.
4. WIPE + REWRITE `derived_state` (not `tracks` history, not `transitions` audit) with
   `generation`+`config_version` stamped. Running twice yields identical `derived_state`.
5. bump `meta.generation`; commit. Never touches `conviction_history` or scheduled `transitions`.
The Swift app reads `derived_state` for the live track view; `tracks`/`transitions`/`conviction_history`
remain the scheduled-run record for audit + history charts.

---

## 4. Migrations
Ordered functions `migrate_1_to_2(con)`, etc. On startup appctl/store: read `meta.schema_version`;
if < code version → SQLite **backup API** to `state/backups/pre-migr-<ts>.sqlite`, verify (integrity_check
+ row counts), then run migrations in one tx each; refuse to run if db schema > code max_supported.

## 5. Locks, pragmas, perms
- flock at `state/.run.lock` (existing). Lock metadata sidecar `state/.run.lock.meta` (JSON: pid,
  proc_start, cmd, acquired_at) for health display; flock is authoritative.
- Swift connections: `PRAGMA query_only=ON; busy_timeout=5000; journal_mode=WAL (read)`. Refuse
  queries until `meta.schema_version` is in [min,max].
- Permissions: `state/market.sqlite`, `state/backups/*`, `out/logs/*`, config archives → chmod 0600.
  Structured logs redacted; notification body may name tickers only (no position sizes).

## 6. App ↔ paths
ROOT=`/Users/YOUR_USERNAME/Projects/Market`. venv python, appctl.py, db all absolute under ROOT. App bundle
stores ROOT in its settings; resolves all backend paths from it (never PATH/cwd). Install to
`/Applications/Market.app` (moved from `~/Applications` 2026-07-24; the fleet is unified in `/Applications`).

AMENDED 2026-08-04 (schema v6, weekly-close position valuation): `position_quotes` is the
latest-state projection for held positions. Keys are canonical uppercase-trimmed
`(symbol TEXT NOT NULL, currency TEXT NOT NULL)`. `min_supported=2`, `schema_version=6`,
and `max_supported=6`; v5→v6 is additive and uses the existing verified SQLite backup
mechanism. `close_price` is canonical locale-independent decimal `TEXT` (not `REAL`),
and the cached quote group (`close_price`, `week_ending`, `market_date`,
`fetched_at`, `source`) is either entirely absent or entirely present. The attempt group is
`fetch_outcome` (`ok|transient_error|unsupported`), `target_week_ending`,
`last_attempt_at`, nullable bounded `last_error_code`, nonnegative `failure_count`, and
nullable `retry_after`. Checks enforce canonical nonblank keys, cached all-or-none, and
the allowed attempt tuples: `ok` clears error/count/backoff, `unsupported` has an error
and no retry, and `transient_error` has an error plus positive count/backoff. Application
code accepts only finite positive close prices.

Market refreshes at most two due USD/direct-Yahoo-compatible held symbols per 15-minute
tick, ordered never-attempted then oldest attempt, under a quote-specific nonblocking
flock. The target is the current New-York calendar Friday at/after 17:15 America/New_York,
otherwise the preceding Friday. `exchange_calendars` XNYS selects the actual last session
in that Monday–Friday week; a Friday holiday therefore stores Friday as `week_ending` and
the preceding Thursday as `market_date`. Yahoo chart requests use unadjusted daily closes,
15-second timeout, a 2 MiB body limit, and bounds extending at least three calendar days
beyond the expected session. Remote/identity/currency/malformed/missing/duplicate-bar
failures are transient; non-USD and deterministic invalid local syntax are unsupported.
Successful weekly closes are authoritative for that symbol/week and survive transient
failures. Backoff is target-scoped and bounded; rollover resets retry state. Current
position joins ignore sold/orphan quote rows.

Runway remains read-only. It feature-detects `position_quotes` with `/usr/bin/sqlite3
-readonly -json` off the main actor and falls back to the v5 positions-only query when the
table is absent. Each lot is valued independently as quantity × matching-currency valid
weekly close, otherwise quantity × that lot's own per-share cost basis; malformed or
overflowing values are unavailable/excluded rather than silently zeroed or converted.
Display labels expose exact market/week dates and freshness/error/fallback states (the
card action is `Reload Market Data`). Theoretical positions, expected return, cash runway,
and user controls remain unchanged. The dispatcher invokes the updater as an isolated
probe; quote failures never change ingest/debrief/watchdog success.
