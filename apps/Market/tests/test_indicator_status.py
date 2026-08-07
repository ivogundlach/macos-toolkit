"""Tests for the indicator-suite status plane (indicator_status.py, schema v5).
Run: python3 tests/test_indicator_status.py

Covers: config-driven parsing (format-tolerant keyword scan), the status projection,
state-change detection (previous_state + changed_at), and idempotency of update().
"""
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))
import indicator_status as ind
import migrate
import store


def cfg():
    with open(os.path.join(ROOT, "config.json")) as f:
        return json.load(f)


C = cfg()


def fresh_con():
    con = sqlite3.connect(":memory:")
    con.executescript(store.DDL)      # events + v1 tables
    con.executescript(migrate.DDL_V5)  # indicator_reads + indicator_status
    return con


def add_alert(con, native_id, ts, text, tickers):
    store.insert_event(
        con, source="tradingview", native_id=native_id, ts=ts, rank=2,
        author="indicator-suite alert", type_="alert", text=text, tickers=tickers)


def check(name, cond):
    print(("PASS" if cond else "FAIL"), name)
    assert cond, name


# --- parse_event: pure parsing ------------------------------------------------

def test_parse_arch_green_weekly():
    r = ind.parse_event("Arch turned GREEN on the weekly, early phase below zero",
                        ["NVDA"], C, event_id="e1", ts="2026-07-07T14:00:00+00:00")
    check("arch: one reading", len(r) == 1)
    x = r[0]
    check("arch: indicator", x["indicator"] == "arch")
    check("arch: bullish (green)", x["state"] == "bullish")
    check("arch: timeframe weekly", x["timeframe"] == "WEEKLY")
    check("arch: phase early", x["detail"].get("phase") == "early")
    check("arch: zero below", x["detail"].get("zero") == "below_zero")
    check("arch: ticker uppercased", x["ticker"] == "NVDA")


def test_parse_helix_purple():
    r = ind.parse_event("HELIX purple intersection 1D", ["AMD"], C,
                        event_id="e2", ts="2026-07-07T15:00:00+00:00")
    check("helix: one reading", len(r) == 1)
    check("helix: bearish (purple)", r[0]["state"] == "bearish")
    check("helix: timeframe 1D", r[0]["timeframe"] == "1D")


def test_parse_two_indicators_two_tickers():
    r = ind.parse_event("Arch green and Helix green", ["AAPL", "MSFT"], C, event_id="e3", ts="t")
    # 2 tickers x 2 indicators = 4 readings, all bullish
    check("multi: 4 readings", len(r) == 4)
    check("multi: all bullish", all(x["state"] == "bullish" for x in r))
    check("multi: distinct read_ids", len({x["read_id"] for x in r}) == 4)


def test_parse_mixed_states_bind_nearest():
    # One alert, two indicators with DIFFERENT colors: each indicator must bind to
    # the state keyword nearest its own mention, not the first keyword in the text.
    r = ind.parse_event("Arch turned GREEN but Helix flipped PURPLE on the daily",
                        ["NVDA"], C, event_id="e5", ts="t")
    states = {x["indicator"]: x["state"] for x in r}
    check("mixed: 2 readings", len(r) == 2)
    check("mixed: arch bullish", states.get("arch") == "bullish")
    check("mixed: helix bearish", states.get("helix") == "bearish")


def test_parse_skips_non_alerts():
    check("skip: no ticker", ind.parse_event("Arch green", [], C, event_id="e") == [])
    check("skip: no indicator", ind.parse_event("green weekly", ["NVDA"], C, event_id="e") == [])
    check("skip: no state", ind.parse_event("Arch weekly", ["NVDA"], C, event_id="e") == [])


# --- projection + change detection -------------------------------------------

def status_row(con, ticker, indicator, timeframe):
    r = con.execute(
        "SELECT state, previous_state, changed_at, last_read_at, read_count "
        "FROM indicator_status WHERE ticker=? AND indicator=? AND timeframe=?",
        (ticker, indicator, timeframe)).fetchone()
    return r


def test_projection_and_change():
    con = fresh_con()
    # T0: NVDA Arch green (weekly)
    add_alert(con, "m1", "2026-07-01T14:00:00+00:00", "Arch GREEN weekly", ["NVDA"])
    with con:
        new, n = ind.update(con, C)
    check("proj: 1 read inserted", new == 1)
    check("proj: 1 status row", n == 1)
    row = status_row(con, "NVDA", "arch", "WEEKLY")
    check("proj: current bullish", row[0] == "bullish")
    check("proj: no previous yet", row[1] is None)
    check("proj: changed_at = first ts", row[2] == "2026-07-01T14:00:00+00:00")

    # T1: same state again -> no change, changed_at stays, read_count grows
    add_alert(con, "m2", "2026-07-03T14:00:00+00:00", "Arch GREEN weekly", ["NVDA"])
    with con:
        ind.update(con, C)
    row = status_row(con, "NVDA", "arch", "WEEKLY")
    check("proj: still bullish", row[0] == "bullish")
    check("proj: changed_at unchanged on repeat", row[2] == "2026-07-01T14:00:00+00:00")
    check("proj: read_count 2", row[4] == 2)

    # T2: FLIP to purple -> previous_state set, changed_at advances
    add_alert(con, "m3", "2026-07-05T14:00:00+00:00", "Arch PURPLE weekly late", ["NVDA"])
    with con:
        ind.update(con, C)
    row = status_row(con, "NVDA", "arch", "WEEKLY")
    check("flip: now bearish", row[0] == "bearish")
    check("flip: previous bullish", row[1] == "bullish")
    check("flip: changed_at = flip ts", row[2] == "2026-07-05T14:00:00+00:00")
    check("flip: read_count 3", row[4] == 3)


def test_idempotency():
    con = fresh_con()
    add_alert(con, "m1", "2026-07-01T14:00:00+00:00", "Helix GREEN 1D", ["AMD"])
    with con:
        new1, _ = ind.update(con, C)
    with con:
        new2, _ = ind.update(con, C)  # second run: no new events
    check("idem: first run inserts", new1 == 1)
    check("idem: second run inserts nothing", new2 == 0)
    # status identical + single row
    rows = con.execute("SELECT COUNT(*) FROM indicator_status").fetchone()[0]
    check("idem: one status row", rows == 1)


if __name__ == "__main__":
    test_parse_arch_green_weekly()
    test_parse_helix_purple()
    test_parse_two_indicators_two_tickers()
    test_parse_mixed_states_bind_nearest()
    test_parse_skips_non_alerts()
    test_projection_and_change()
    test_idempotency()
    print("\nAll indicator_status tests passed.")
