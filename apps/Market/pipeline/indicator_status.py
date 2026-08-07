"""Indicator-suite per-stock STATUS plane (schema v5).

Deterministic projection, SEPARATE from the LLM conviction state machine
(derived_state/transitions/conviction_history). It reads the raw TradingView
indicator-suite alert events and maintains, per (ticker, indicator, timeframe):
its current state (bullish/bearish/neutral), the previous state, and when it last
changed — so Market.app can show "what stands where, and since when", accruing
history over time.

Data flow (called from run.py after ingest, inside the caller's transaction/lock):
  events(source in cfg.indicator_alerts.sources)
    -> parse_event()  (config-driven keyword/regex extraction)
    -> indicator_reads (append-only, INSERT OR IGNORE — replay is always safe)
    -> recompute indicator_status  (wipe + rewrite from indicator_reads; deterministic)

FORMAT PIN POINT
----------------
The exact TradingView alert wording is not yet known (indicator-suite alerts are
paused ~a few weeks as of 2026-07-07, and a live look was declined). The parser is
therefore config-driven and format-tolerant: it does NOT assume field order. It gets
the ticker from events.tickers (already extracted by adapters/tradingview_gmail.py)
and scans the alert text for indicator names, state colors/words, timeframe tokens,
and phase words using the maps in config.json -> "indicator_alerts". When a real
sample arrives, tune those maps (or add "regex_rules") — no code change needed.

Green = bullish, Purple = bearish (knowledge/indicator-suite.md).
"""
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store
import util

# Sensible defaults if config.json has no "indicator_alerts" block yet. Keep these
# aligned with knowledge/indicator-suite.md (Arch + Helix; green bull / purple bear).
DEFAULTS = {
    "enabled": True,
    "sources": ["tradingview"],
    "indicators": ["arch", "helix"],
    "state_keywords": {
        "bullish": ["green", "bullish", "bull", "long", "buy"],
        "bearish": ["purple", "bearish", "bear", "short", "sell"],
        "neutral": ["neutral", "flat", "cross", "intersection"],
    },
    "phase_keywords": {"early": ["early"], "late": ["late"]},
    "zero_keywords": {"below_zero": ["below zero", "below 0"],
                      "above_zero": ["above zero", "above 0"]},
    # timeframe tokens like 1W, 4H, 15m, or words like weekly/daily
    "timeframe_patterns": [
        r"\b(\d{1,3}\s?(?:mo|w|d|h|m|min))\b",
        r"\b(weekly|daily|monthly|hourly|intraday|4-hour|1-hour)\b",
    ],
    "default_timeframe": "",
    # Optional precise rules (list of {"regex": ..., named groups ticker/indicator/timeframe/signal}).
    # Empty by default; add once the real alert format is known for exact parsing.
    "regex_rules": [],
}


def _cfg(cfg):
    c = dict(DEFAULTS)
    c.update(cfg.get("indicator_alerts") or {})
    # merge nested keyword dicts so a partial config override doesn't wipe defaults
    for k in ("state_keywords", "phase_keywords", "zero_keywords"):
        merged = dict(DEFAULTS[k])
        merged.update((cfg.get("indicator_alerts") or {}).get(k, {}))
        c[k] = merged
    return c


def read_id(event_id, ticker, indicator, timeframe):
    return hashlib.sha256(f"{event_id}:{ticker}:{indicator}:{timeframe}".encode()).hexdigest()


STATE_ORDER = ("bullish", "bearish", "neutral")


def _state_occurrences(text_lower, state_keywords):
    """All (index, state) keyword occurrences in the text, sorted by position.

    Deterministic: positions ascending; ties broken by the fixed STATE_ORDER.
    """
    occ = []
    for rank, state in enumerate(STATE_ORDER):
        for kw in state_keywords.get(state, []):
            start = 0
            k = kw.lower()
            while True:
                idx = text_lower.find(k, start)
                if idx == -1:
                    break
                occ.append((idx, rank, state))
                start = idx + 1
    occ.sort()
    return [(idx, state) for idx, _rank, state in occ]


def _first_state(text_lower, state_keywords):
    """Return the canonical state whose keyword appears earliest in the text, else None."""
    occ = _state_occurrences(text_lower, state_keywords)
    return occ[0][1] if occ else None


def _nearest_state(occurrences, anchor_idx):
    """State for the indicator mentioned at anchor_idx.

    One alert can carry different states for different indicators ("Arch GREEN but
    Helix PURPLE"). Alert phrasing puts the state AFTER the indicator name, so bind
    to the first state keyword after the mention; fall back to the nearest one
    before it ("GREEN Arch" style). Deterministic either way.
    """
    after = [(idx, state) for idx, state in occurrences if idx >= anchor_idx]
    if after:
        return min(after)[1]
    before = [(anchor_idx - idx, idx, state) for idx, state in occurrences]
    return min(before)[2] if before else None


def _scan_bucket(text_lower, buckets):
    """Return the first bucket key whose any keyword appears, else None."""
    for key, kws in buckets.items():
        for kw in kws:
            if kw.lower() in text_lower:
                return key
    return None


def _timeframe(text, patterns, default):
    for pat in patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            return m.group(1).replace(" ", "").upper()
    return default


def parse_event(text, tickers, cfg, event_id="", ts="", session_date=""):
    """Parse one alert event into zero or more indicator readings.

    Pure function (no DB). Returns a list of dicts:
      {read_id, event_id, ts, session_date, ticker, indicator, timeframe, state, detail}
    Emits one reading per (ticker x indicator) found. Skips the event if no ticker,
    no known indicator, or no resolvable state (i.e. it isn't a suite alert we understand).
    """
    ic = _cfg(cfg)
    text = text or ""
    tl = text.lower()
    tickers = [t for t in (tickers or []) if t]
    if not tickers:
        return []

    # 1) explicit regex rules first (exact parsing once the format is pinned)
    readings = []
    for rule in ic.get("regex_rules", []):
        for m in re.finditer(rule["regex"], text, re.IGNORECASE):
            gd = m.groupdict()
            tk = (gd.get("ticker") or (tickers[0] if tickers else "")).upper()
            ind = (gd.get("indicator") or "").lower()
            tf = (gd.get("timeframe") or ic["default_timeframe"]).upper()
            sig = (gd.get("signal") or "").lower()
            state = _first_state(sig or tl, ic["state_keywords"])
            if tk and ind and state:
                readings.append((tk, ind, tf, state, {"rule": True, "signal": sig}))
    if readings:
        return _emit(readings, tickers, text, tl, ic, event_id, ts, session_date)

    # 2) keyword scan (format-tolerant default). Which indicators are named?
    # Each indicator binds to the state keyword NEAREST its own mention, so one
    # alert carrying different states ("Arch GREEN but Helix PURPLE") parses right.
    inds = [(ind, tl.find(ind.lower())) for ind in ic["indicators"] if ind.lower() in tl]
    if not inds:
        return []
    occurrences = _state_occurrences(tl, ic["state_keywords"])
    if not occurrences:
        return []
    tf = _timeframe(text, ic["timeframe_patterns"], ic["default_timeframe"])
    phase = _scan_bucket(tl, ic["phase_keywords"])
    zero = _scan_bucket(tl, ic["zero_keywords"])
    detail = {}
    if phase:
        detail["phase"] = phase
    if zero:
        detail["zero"] = zero
    tuples = [(tk.upper(), ind.lower(), tf, _nearest_state(occurrences, ind_idx), dict(detail))
              for tk in tickers for ind, ind_idx in inds]
    return _emit(tuples, tickers, text, tl, ic, event_id, ts, session_date)


def _emit(tuples, tickers, text, tl, ic, event_id, ts, session_date):
    out = []
    seen = set()
    for tk, ind, tf, state, detail in tuples:
        key = (tk, ind, tf)
        if key in seen:
            continue
        seen.add(key)
        d = dict(detail)
        d.setdefault("text", text[:400])
        out.append({
            "read_id": read_id(event_id, tk, ind, tf),
            "event_id": event_id, "ts": ts, "session_date": session_date,
            "ticker": tk, "indicator": ind, "timeframe": tf,
            "state": state, "detail": d,
        })
    return out


def ingest_reads(con, cfg):
    """Parse any indicator-alert events not yet in indicator_reads; insert (INSERT OR IGNORE).

    Returns the number of newly inserted read rows. Caller holds the transaction.
    """
    ic = _cfg(cfg)
    if not ic.get("enabled", True):
        return 0
    sources = ic.get("sources", ["tradingview"])
    placeholders = ",".join("?" for _ in sources)
    rows = con.execute(
        f"SELECT event_id, ts, session_date, text, tickers FROM events "
        f"WHERE source IN ({placeholders})", tuple(sources)).fetchall()
    new = 0
    for event_id, ts, session_date, text, tickers_json in rows:
        try:
            tickers = json.loads(tickers_json or "[]")
        except json.JSONDecodeError:
            tickers = []
        for r in parse_event(text, tickers, cfg, event_id=event_id, ts=ts, session_date=session_date):
            cur = con.execute(
                "INSERT OR IGNORE INTO indicator_reads "
                "(read_id, event_id, ts, session_date, ticker, indicator, timeframe, state, detail) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (r["read_id"], r["event_id"], r["ts"], r["session_date"],
                 r["ticker"], r["indicator"], r["timeframe"], r["state"],
                 json.dumps(r["detail"], sort_keys=True)))
            new += cur.rowcount
    return new


def recompute_status(con):
    """Wipe + rewrite indicator_status from indicator_reads. Deterministic projection.

    For each (ticker, indicator, timeframe): current state = latest reading's state;
    changed_at = ts the current contiguous state-run began; previous_state = the state
    just before that run (NULL if the current state is the first ever seen).
    Returns the number of status rows written. Caller holds the transaction.
    """
    rows = con.execute(
        "SELECT ticker, indicator, timeframe, ts, state, detail, read_id "
        "FROM indicator_reads ORDER BY ticker, indicator, timeframe, ts ASC, read_id ASC"
    ).fetchall()

    groups = {}
    for ticker, indicator, timeframe, ts, state, detail, _rid in rows:
        groups.setdefault((ticker, indicator, timeframe), []).append((ts, state, detail))

    con.execute("DELETE FROM indicator_status")
    written = 0
    for (ticker, indicator, timeframe), reads in sorted(groups.items()):
        cur_state = reads[0][1]
        changed_at = reads[0][0]      # start of the current contiguous run
        previous_state = None
        for ts, state, _detail in reads[1:]:
            if state != cur_state:
                previous_state = cur_state
                cur_state = state
                changed_at = ts
        last_ts, _last_state, last_detail = reads[-1]
        con.execute(
            "INSERT INTO indicator_status "
            "(ticker, indicator, timeframe, state, previous_state, changed_at, "
            "last_read_at, detail, read_count) VALUES (?,?,?,?,?,?,?,?,?)",
            (ticker, indicator, timeframe, cur_state, previous_state, changed_at,
             last_ts, last_detail, len(reads)))
        written += 1
    return written


def update(con, cfg):
    """Ingest new reads + recompute the status projection. Caller holds the transaction.

    Returns (n_new_reads, n_status_rows). Idempotent: a second call with unchanged
    events produces byte-identical indicator_status.
    """
    new = ingest_reads(con, cfg)
    n = recompute_status(con)
    return new, n


def main():
    cfg = store.config()
    con = store.connect()
    with con:
        new, n = update(con, cfg)
    util.log("indicator_status", f"done: +{new} reads, {n} status rows")


if __name__ == "__main__":
    main()
