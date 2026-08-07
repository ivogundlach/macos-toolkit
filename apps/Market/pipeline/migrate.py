"""Schema migrations + version gating for the canonical store (CONTRACTS.md §2, §4).

Ordered functions migrate_1_to_2(con), ... . On startup store.connect() calls ensure_schema():
  - read meta.schema_version (absent == legacy v1);
  - refuse if db schema > code MAX_SCHEMA (don't corrupt a newer db with older code);
  - if db schema < code MAX_SCHEMA: SQLite backup-API copy to state/backups/pre-migr-<ts>.sqlite,
    verify the backup (integrity_check + table row counts), then run each migration in its own tx.

The migration is idempotent at the table level (CREATE TABLE IF NOT EXISTS / INDEX IF NOT EXISTS);
schema_version gating prevents re-running a completed migration.
"""
import os
import sqlite3
import stat
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIN_SCHEMA = 2          # Swift refuses queries outside [min,max]; v3/v4/v5 are additive so v2 readers stay valid
MAX_SCHEMA = 6          # highest schema this code can produce/operate
CODE_SCHEMA = 6         # target version this code migrates a fresh/old db up to

# --- v2 DDL (new tables + indexes). Existing v1 tables stay in store.DDL. ---
DDL_V2 = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

CREATE TABLE IF NOT EXISTS derived_state (
  ticker TEXT PRIMARY KEY, track TEXT, status TEXT, conviction REAL,
  entered_at TEXT, last_signal_at TEXT, source TEXT,
  config_version INTEGER, generation INTEGER);

CREATE TABLE IF NOT EXISTS overrides (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ticker TEXT NOT NULL,
  op TEXT NOT NULL, track TEXT, note TEXT,
  created_at TEXT NOT NULL, tombstoned_at TEXT,
  UNIQUE(ticker, op, track) ON CONFLICT REPLACE);

CREATE TABLE IF NOT EXISTS positions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, symbol TEXT NOT NULL,
  quantity TEXT NOT NULL, cost_basis TEXT, currency TEXT NOT NULL DEFAULT 'USD',
  account TEXT NOT NULL DEFAULT '', provenance TEXT NOT NULL DEFAULT 'manual',
  opened_at TEXT, updated_at TEXT NOT NULL,
  UNIQUE(symbol, account, provenance));

CREATE TABLE IF NOT EXISTS watchlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL,
  tickers TEXT NOT NULL DEFAULT '[]', provenance TEXT NOT NULL DEFAULT 'manual',
  scraped_at TEXT, stale INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
  UNIQUE(name, provenance));

CREATE TABLE IF NOT EXISTS conviction_history (
  ticker TEXT NOT NULL, run_id TEXT NOT NULL, session_date TEXT NOT NULL,
  track TEXT, conviction REAL, PRIMARY KEY (ticker, run_id));

CREATE TABLE IF NOT EXISTS notifications (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL, ticker TEXT, run_id TEXT, body TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL, delivered_at TEXT, lease_until TEXT);

CREATE INDEX IF NOT EXISTS idx_ch_ticker ON conviction_history(ticker, session_date);
CREATE INDEX IF NOT EXISTS idx_overrides_ticker ON overrides(ticker) WHERE tombstoned_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notif_state ON notifications(state);
"""


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def get_schema_version(con):
    """Read meta.schema_version. A v1 db has no meta table -> version 1."""
    row = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta'").fetchone()
    if not row:
        return 1
    r = con.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    return int(r[0]) if r and r[0] is not None else 1


def _set_meta(con, key, value):
    con.execute("INSERT INTO meta(key,value) VALUES(?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))


def _table_names(con):
    return sorted(r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))


def _row_counts(con):
    return {t: con.execute(f"SELECT COUNT(*) FROM \"{t}\"").fetchone()[0]
            for t in _table_names(con)}


def backup_db(src_path):
    """SQLite backup-API copy to state/backups/pre-migr-<ts>.sqlite. Returns backup path.

    Verifies the backup: integrity_check == 'ok' and per-table row counts match the source.
    chmod 0600 on the backup (CONTRACTS.md §5).
    """
    backup_dir = os.path.join(ROOT, "state", "backups")
    os.makedirs(backup_dir, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dst_path = os.path.join(backup_dir, f"pre-migr-{ts}.sqlite")

    src = sqlite3.connect(src_path)
    dst = sqlite3.connect(dst_path)
    try:
        dst.execute("PRAGMA journal_mode=DELETE")  # self-contained single-file backup, no WAL sidecars
        with dst:
            src.backup(dst)  # online backup API
        ic = dst.execute("PRAGMA integrity_check").fetchone()[0]
        if ic != "ok":
            raise RuntimeError(f"backup integrity_check failed: {ic!r}")
        src_counts, dst_counts = _row_counts(src), _row_counts(dst)
        if src_counts != dst_counts:
            raise RuntimeError(f"backup row-count mismatch: src={src_counts} dst={dst_counts}")
    finally:
        src.close()
        dst.close()
    # remove any transient sidecars; the backup is a complete single file
    for ext in ("-wal", "-shm", "-journal"):
        sidecar = dst_path + ext
        if os.path.exists(sidecar):
            os.remove(sidecar)
    os.chmod(dst_path, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    return dst_path


# --- ordered migrations ---

def migrate_1_to_2(con):
    """v1 -> v2: add app-control tables + indexes + meta. Keeps all v1 tables intact."""
    con.executescript(DDL_V2)
    _set_meta(con, "schema_version", 2)
    _set_meta(con, "min_supported", MIN_SCHEMA)
    _set_meta(con, "max_supported", MAX_SCHEMA)
    # generation: preserve if already present (re-entrancy), else seed at 0
    r = con.execute("SELECT value FROM meta WHERE key='generation'").fetchone()
    if not r:
        _set_meta(con, "generation", 0)


# v3: sentiment-analyst columns on signals (additive; v2 readers unaffected).
V3_SIGNAL_COLUMNS = (
    ("model_conviction", "REAL"),   # raw LLM conviction 0-100
    ("capped_conviction", "REAL"),  # after rank-based cap; the value that feeds state
    ("thesis_type", "TEXT"),        # catalyst|valuation|technical|momentum|meme|other
    ("horizon", "TEXT"),            # days|weeks|months|years|unspecified
    ("justification", "TEXT"),      # model's written reasoning (bounded)
    ("speakers", "TEXT"),           # JSON: per-speaker sentiment/conviction + verified quotes
)


def migrate_2_to_3(con):
    """v2 -> v3: add sentiment-analyst columns to signals. Column-guarded, re-entrant."""
    existing = {r[1] for r in con.execute("PRAGMA table_info(signals)")}
    for name, typ in V3_SIGNAL_COLUMNS:
        if name not in existing:
            con.execute(f"ALTER TABLE signals ADD COLUMN {name} {typ}")
    _set_meta(con, "schema_version", 3)
    _set_meta(con, "min_supported", MIN_SCHEMA)
    _set_meta(con, "max_supported", MAX_SCHEMA)


def migrate_3_to_4(con):
    """v3 -> v4: full debrief content lives in the db (email delivery retired 2026-07-01).
    runs_debrief gains debrief_json + run_id; the table itself may be absent (it was created
    ad hoc by run.py before v4). Column-guarded, re-entrant."""
    con.execute("CREATE TABLE IF NOT EXISTS runs_debrief ("
                "session_date TEXT PRIMARY KEY, headline TEXT, "
                "debrief_json TEXT, run_id TEXT)")
    existing = {r[1] for r in con.execute("PRAGMA table_info(runs_debrief)")}
    for name, typ in (("debrief_json", "TEXT"), ("run_id", "TEXT")):
        if name not in existing:
            con.execute(f"ALTER TABLE runs_debrief ADD COLUMN {name} {typ}")
    _set_meta(con, "schema_version", 4)
    _set_meta(con, "min_supported", MIN_SCHEMA)
    _set_meta(con, "max_supported", MAX_SCHEMA)


# v5: indicator-suite per-stock STATUS plane (deterministic; parsed from TradingView
# indicator-suite alert events). SEPARATE from the LLM conviction state machine
# (derived_state/transitions/conviction_history) — this is a factual readout of the raw
# Arch/Helix states, not an opinion score. Two tables:
#   indicator_reads  — append-only history: one row per parsed alert reading (immutable).
#   indicator_status — current projection: latest state per (ticker,indicator,timeframe) +
#                      previous_state + changed_at, so the app can show "what stands where,
#                      and since when". Wiped+rewritten deterministically from indicator_reads.
# Additive only; v2+ readers ignore the new tables (they read via tableExists guards).
DDL_V5 = """
CREATE TABLE IF NOT EXISTS indicator_reads (
  read_id TEXT PRIMARY KEY,              -- sha256(event_id:ticker:indicator:timeframe)
  event_id TEXT NOT NULL,                -- source alert event (events.event_id)
  ts TEXT NOT NULL,                      -- alert content timestamp, UTC ISO-8601
  session_date TEXT NOT NULL,
  ticker TEXT NOT NULL,
  indicator TEXT NOT NULL,               -- arch | helix | ... (config-driven)
  timeframe TEXT NOT NULL,               -- 1W | 1D | 4H | ... | '' when unknown
  state TEXT NOT NULL,                   -- bullish | bearish | neutral
  detail TEXT NOT NULL DEFAULT '{}'      -- JSON: phase (early/late), zero-side, raw label, alert text
);
CREATE INDEX IF NOT EXISTS idx_ind_reads_key ON indicator_reads(ticker, indicator, timeframe, ts);

CREATE TABLE IF NOT EXISTS indicator_status (
  ticker TEXT NOT NULL,
  indicator TEXT NOT NULL,
  timeframe TEXT NOT NULL,
  state TEXT NOT NULL,
  previous_state TEXT,                   -- state before the most recent change (NULL if never changed)
  changed_at TEXT,                       -- ts the CURRENT state was entered (start of current run)
  last_read_at TEXT NOT NULL,            -- ts of the most recent reading (change or not)
  detail TEXT NOT NULL DEFAULT '{}',     -- detail JSON from the latest reading
  read_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (ticker, indicator, timeframe)
);
CREATE INDEX IF NOT EXISTS idx_ind_status_changed ON indicator_status(changed_at DESC);
"""


def migrate_4_to_5(con):
    """v4 -> v5: add the indicator-suite status plane (indicator_reads + indicator_status).
    Additive tables + indexes only; re-entrant (CREATE ... IF NOT EXISTS)."""
    con.executescript(DDL_V5)
    _set_meta(con, "schema_version", 5)
    _set_meta(con, "min_supported", MIN_SCHEMA)
    _set_meta(con, "max_supported", MAX_SCHEMA)


# v6: latest weekly close and retry state for held positions.  This is a current-state
# projection, not a weekly history table.  Cached quote fields are all-or-none; an attempt
# row may retain an older cached quote while a new target week is being retried.
DDL_V6 = """
CREATE TABLE IF NOT EXISTS position_quotes (
  symbol TEXT NOT NULL,
  currency TEXT NOT NULL,
  close_price TEXT,
  week_ending TEXT,
  market_date TEXT,
  fetched_at TEXT,
  source TEXT,
  fetch_outcome TEXT NOT NULL,
  target_week_ending TEXT NOT NULL,
  last_attempt_at TEXT NOT NULL,
  last_error_code TEXT,
  failure_count INTEGER NOT NULL DEFAULT 0,
  retry_after TEXT,
  PRIMARY KEY (symbol, currency),
  CHECK (length(symbol) > 0 AND symbol = trim(symbol) AND symbol = upper(symbol)),
  CHECK (length(currency) > 0 AND currency = trim(currency) AND currency = upper(currency)),
  CHECK (
    (close_price IS NULL AND week_ending IS NULL AND market_date IS NULL AND fetched_at IS NULL AND source IS NULL)
    OR
    (close_price IS NOT NULL AND typeof(close_price) = 'text' AND close_price = trim(close_price)
     AND length(close_price) > 0 AND close_price GLOB '[0-9]*'
     AND close_price NOT GLOB '*[^0-9.]*' AND close_price NOT GLOB '*.*.*'
     AND week_ending IS NOT NULL AND market_date IS NOT NULL
     AND fetched_at IS NOT NULL AND source IS NOT NULL)
  ),
  CHECK (fetch_outcome IN ('ok', 'transient_error', 'unsupported')),
  CHECK (length(target_week_ending) > 0 AND target_week_ending = trim(target_week_ending)),
  CHECK (length(last_attempt_at) > 0 AND last_attempt_at = trim(last_attempt_at)),
  CHECK (last_error_code IS NULL OR (length(trim(last_error_code)) BETWEEN 1 AND 96 AND last_error_code = trim(last_error_code))),
  CHECK (failure_count >= 0),
  CHECK (
    (fetch_outcome = 'ok' AND last_error_code IS NULL AND failure_count = 0 AND retry_after IS NULL
     AND close_price IS NOT NULL)
    OR
    (fetch_outcome = 'unsupported' AND last_error_code IS NOT NULL AND retry_after IS NULL)
    OR
    (fetch_outcome = 'transient_error' AND last_error_code IS NOT NULL AND failure_count > 0
     AND retry_after IS NOT NULL AND length(trim(retry_after)) > 0 AND retry_after = trim(retry_after))
  )
);
CREATE INDEX IF NOT EXISTS idx_position_quotes_outcome
  ON position_quotes(fetch_outcome, target_week_ending, retry_after);
"""


def migrate_5_to_6(con):
    """v5 -> v6: add the latest weekly-close position quote projection."""
    con.executescript(DDL_V6)
    _set_meta(con, "schema_version", 6)
    _set_meta(con, "min_supported", MIN_SCHEMA)
    _set_meta(con, "max_supported", MAX_SCHEMA)


MIGRATIONS = {1: migrate_1_to_2, 2: migrate_2_to_3, 3: migrate_3_to_4,
              4: migrate_4_to_5, 5: migrate_5_to_6}  # version N -> produces N+1


def ensure_schema(con, db_path):
    """Idempotent: bring db up to CODE_SCHEMA, gated + backed up. Safe to call every connect()."""
    current = get_schema_version(con)
    if current > MAX_SCHEMA:
        raise RuntimeError(
            f"db schema_version {current} > code max_supported {MAX_SCHEMA}; refusing to run "
            f"(upgrade the code, do not let older code touch a newer db)")
    if current >= CODE_SCHEMA:
        return current  # already current; no work, no backup

    # back up once before applying the chain
    backup_db(db_path)
    v = current
    while v < CODE_SCHEMA:
        mig = MIGRATIONS.get(v)
        if mig is None:
            raise RuntimeError(f"no migration registered for schema {v}")
        with con:  # one transaction per migration step
            mig(con)
        v += 1
    return v
