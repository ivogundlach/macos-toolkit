"""Canonical SQLite store. All adapters write events through here; JSONL is a derived export."""
import hashlib
import json
import os
import sqlite3
import stat
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import migrate

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NY = ZoneInfo("America/New_York")
SCHEMA_VERSION = 1

DDL = """
CREATE TABLE IF NOT EXISTS events (
  event_id TEXT PRIMARY KEY,
  schema_version INTEGER NOT NULL,
  ts TEXT NOT NULL,
  ingested_at TEXT NOT NULL,
  session_date TEXT NOT NULL,
  source TEXT NOT NULL,
  rank INTEGER NOT NULL,
  author TEXT NOT NULL,
  type TEXT NOT NULL,
  text TEXT NOT NULL,
  tickers TEXT NOT NULL DEFAULT '[]',
  urls TEXT NOT NULL DEFAULT '[]',
  engagement TEXT NOT NULL DEFAULT '{}',
  raw_ref TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_date, source);
CREATE TABLE IF NOT EXISTS regime (
  session_date TEXT PRIMARY KEY,
  captured_at TEXT NOT NULL,
  vix REAL, vix_trend5d REAL, fear_greed REAL, put_call REAL, oi_note TEXT,
  score REAL, confidence TEXT, formula_version INTEGER, raw TEXT
);
CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  committed_at TEXT,
  kind TEXT NOT NULL,
  watermark TEXT,
  manifest TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS signals (
  signal_id TEXT PRIMARY KEY,           -- sha256(run_id + ticker + origin_key)
  run_id TEXT NOT NULL,
  session_date TEXT NOT NULL,
  ticker TEXT NOT NULL,
  direction TEXT NOT NULL,              -- bullish | bearish
  strength TEXT NOT NULL,               -- strong | moderate | weak
  best_rank INTEGER NOT NULL,
  origin_key TEXT NOT NULL,             -- deterministic provenance id; equal keys = same origin
  track_proposal TEXT NOT NULL,
  event_ids TEXT NOT NULL DEFAULT '[]',
  model_conviction REAL,                -- v3: raw LLM conviction 0-100
  capped_conviction REAL,               -- v3: after rank cap; feeds state
  thesis_type TEXT,                     -- v3: catalyst|valuation|technical|momentum|meme|other
  horizon TEXT,                         -- v3: days|weeks|months|years|unspecified
  justification TEXT,                   -- v3: model's bounded written reasoning
  speakers TEXT                         -- v3: JSON per-speaker sentiment + verified quotes
);
CREATE INDEX IF NOT EXISTS idx_signals_ticker ON signals(ticker, session_date);
CREATE TABLE IF NOT EXISTS tracks (
  ticker TEXT PRIMARY KEY,
  track TEXT NOT NULL,                  -- growth | value | dividends
  status TEXT NOT NULL,                 -- active | exited | conflict
  conviction REAL NOT NULL,
  entered_at TEXT,
  last_signal_at TEXT,
  exited_at TEXT,
  exit_reason TEXT
);
CREATE TABLE IF NOT EXISTS transitions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  session_date TEXT NOT NULL,
  ticker TEXT NOT NULL,
  transition TEXT NOT NULL,             -- T1..T10 per SPEC-state-machine.md
  detail TEXT NOT NULL DEFAULT '{}'     -- arithmetic, evidence ids, config hash
);
CREATE TABLE IF NOT EXISTS runs_debrief (
  session_date TEXT PRIMARY KEY,
  headline TEXT,
  debrief_json TEXT,                    -- v4: full debrief; the app is the sole reader (no email)
  run_id TEXT
);
"""


def config():
    with open(os.path.join(ROOT, "config.json"), encoding="utf-8") as f:
        return json.load(f)


def db_path():
    cfg = config()
    return os.path.join(ROOT, cfg["paths"]["db"])


def connect():
    path = db_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path, timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    con.executescript(DDL)              # v1 tables (idempotent)
    migrate.ensure_schema(con, path)    # v2 tables + version gating + pre-migration backup
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)  # 0600 (CONTRACTS.md §5)
    except OSError:
        pass
    return con


def get_meta(con, key, default=None):
    r = con.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return r[0] if r else default


def set_meta(con, key, value):
    con.execute("INSERT INTO meta(key,value) VALUES(?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))


def bump_generation(con):
    """Monotonic +1 of meta.generation. Caller is inside a transaction."""
    g = int(get_meta(con, "generation", "0")) + 1
    set_meta(con, "generation", g)
    return g


def event_id(source: str, native_id: str) -> str:
    return hashlib.sha256(f"{source}:{native_id}".encode()).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def session_date(ts_iso: str) -> str:
    dt = datetime.fromisoformat(ts_iso.replace("Z", "+00:00"))
    return dt.astimezone(NY).date().isoformat()


def insert_event(con, *, source, native_id, ts, rank, author, type_, text,
                 tickers=(), urls=(), engagement=None, raw_ref=""):
    cfg = config()
    text = (text or "")[: cfg["limits"]["max_event_text_chars"]]
    row = (
        event_id(source, native_id), SCHEMA_VERSION, ts, utc_now(), session_date(ts),
        source, rank, author, type_, text,
        json.dumps(sorted(set(tickers))), json.dumps(list(urls)),
        json.dumps(engagement or {}), raw_ref,
    )
    cur = con.execute(
        "INSERT OR IGNORE INTO events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", row
    )
    return cur.rowcount  # 1 = new, 0 = duplicate


def export_jsonl(con, source: str, day: str):
    """Derived export for human inspection."""
    cfg = config()
    rows = con.execute(
        "SELECT * FROM events WHERE source=? AND session_date=? ORDER BY ts", (source, day)
    )
    cols = [d[0] for d in rows.description]
    out_dir = os.path.join(ROOT, cfg["paths"]["inbox"], source)
    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.join(out_dir, f".{day}.jsonl.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(dict(zip(cols, r)), ensure_ascii=False) + "\n")
    os.replace(tmp, os.path.join(out_dir, f"{day}.jsonl"))
