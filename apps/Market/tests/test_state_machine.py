"""Spec-scenario tests for state_machine.py v2 (sentiment analyst). Run: python3 tests/test_state_machine.py"""
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))
import state_machine as sm
import store


def fresh_con():
    con = sqlite3.connect(":memory:")
    con.executescript(store.DDL)
    return con


def cfg():
    with open(os.path.join(ROOT, "config.json")) as f:
        return json.load(f)


C = cfg()


def cluster(ticker, direction="bullish", conviction=70.0, rank=3, origin="o1",
            track="growth", events=("e1",), thesis="catalyst", horizon="months",
            justification="test justification", speakers=None):
    capped = min(float(conviction), float(C["sentiment"]["rank_conviction_caps"][str(rank)]))
    return {"ticker": ticker, "direction": direction,
            "model_conviction": float(conviction), "conviction": capped,
            "thesis_type": thesis, "horizon": horizon, "justification": justification,
            "speakers": speakers or [{"event_ids": list(events), "sentiment": 80,
                                      "speaker_conviction": 80, "position_disclosed": True,
                                      "hedged": False, "quotes": ["a verified quote"]}],
            "best_rank": rank, "origin_key": origin, "track_proposal": track,
            "event_ids": list(events), "claim": "test claim"}


FRESH = {"growth": True, "value": True, "dividends": True}


def get_track(con, t):
    r = con.execute("SELECT track, status, conviction FROM tracks WHERE ticker=?", (t,)).fetchone()
    return dict(zip(("track", "status", "conviction"), r)) if r else None


def transitions(con, t):
    return [r[0] for r in con.execute("SELECT transition FROM transitions WHERE ticker=? ORDER BY id", (t,))]


# T1 immediate entry: one bullish cluster at conviction 70 (rank 3, cap 80) enters growth at 70
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("NVDA", conviction=70)], 55, FRESH, C)
t = get_track(con, "NVDA")
assert t and t["status"] == "active" and t["track"] == "growth" and t["conviction"] == 70.0, t
assert "T1" in transitions(con, "NVDA")

# Below entry threshold: conviction 55 < entry_conviction 60 -> no entry
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("AMD", conviction=55)], 55, FRESH, C)
assert get_track(con, "AMD") is None

# Rank cap: rank-5 hype at model conviction 90 is capped to 60 -> enters exactly at threshold 60
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("MEME", conviction=90, rank=5)], 55, FRESH, C)
t = get_track(con, "MEME")
assert t and t["conviction"] == 60.0, t  # capped, NOT 90

# T2: bearish regime (30) raises threshold to 90; conviction 70 blocked, audited as T2
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("PLTR", conviction=70)], 30, FRESH, C)
assert get_track(con, "PLTR") is None
assert "T2" in transitions(con, "PLTR")

# Bearish regime still admits a very-high-conviction trusted call: rank 1 conviction 95 >= 90
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("MSFT", conviction=95, rank=1)], 30, FRESH, C)
t = get_track(con, "MSFT")
assert t and t["status"] == "active" and t["conviction"] == 95.0, t

# T3 EMA reinforce: held at 70, new bullish target 90 (rank 2) -> 0.5*70 + 0.5*90 = 80
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("NVDA", conviction=70)], 55, FRESH, C)
sm.apply_run(con, "r2", "2026-06-11", [cluster("NVDA", conviction=90, rank=2, origin="o2")], 55, FRESH, C)
t = get_track(con, "NVDA")
assert t and abs(t["conviction"] - 80.0) < 1e-9, t
assert transitions(con, "NVDA") == ["T1", "T3"]

# EMA cap: reinforcement can never exceed 95
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("NVDA", conviction=95, rank=1)], 55, FRESH, C)
sm.apply_run(con, "r2", "2026-06-11", [cluster("NVDA", conviction=100, rank=1, origin="o2")], 55, FRESH, C)
t = get_track(con, "NVDA")
assert t and t["conviction"] <= 95.0, t

# Bearish pull (below T6 bar): held at 70, rank-3 bearish at 60 -> 0.5*70 - 0.5*60 = 5 -> T5 exit
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("SNAP", conviction=70)], 55, FRESH, C)
sm.apply_run(con, "r2", "2026-06-11",
             [cluster("SNAP", direction="bearish", conviction=60, origin="o2")], 55, FRESH, C)
t = get_track(con, "SNAP")
assert t and t["status"] == "exited" and abs(t["conviction"] - 5.0) < 1e-9, t
assert transitions(con, "SNAP") == ["T1", "T3", "T5"]

# T6: trusted bearish (rank 2, conviction >= exit_bearish_conviction 75) exits immediately
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("TSLA", conviction=80, rank=2)], 55, FRESH, C)
sm.apply_run(con, "r2", "2026-06-11",
             [cluster("TSLA", direction="bearish", conviction=80, rank=2, origin="o2")], 55, FRESH, C)
t = get_track(con, "TSLA")
assert t and t["status"] == "exited", t
assert "T6" in transitions(con, "TSLA")

# Rank-2 bearish BELOW the T6 bar does not rank-override (pulls conviction instead)
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("ORCL", conviction=90, rank=1)], 55, FRESH, C)
sm.apply_run(con, "r2", "2026-06-11",
             [cluster("ORCL", direction="bearish", conviction=50, rank=2, origin="o2")], 55, FRESH, C)
t = get_track(con, "ORCL")
assert t and t["status"] == "active" and "T6" not in transitions(con, "ORCL"), t

# T7: held ticker, bull rank1 vs bear rank3 (gap 2) -> bull wins, reinforced
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("AAPL", conviction=70)], 55, FRESH, C)
sm.apply_run(con, "r2", "2026-06-11",
             [cluster("AAPL", conviction=90, rank=1, origin="o2"),
              cluster("AAPL", direction="bearish", conviction=90, rank=3, origin="o3")], 55, FRESH, C)
t = get_track(con, "AAPL")
assert t and t["status"] == "active" and t["conviction"] > 70, t
assert "T7" in transitions(con, "AAPL")

# T8: comparable-rank conflict on held ticker flags conflict, no exit, no reinforce
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("META", conviction=70)], 55, FRESH, C)
sm.apply_run(con, "r2", "2026-06-11",
             [cluster("META", conviction=90, rank=2, origin="o2"),
              cluster("META", direction="bearish", conviction=90, rank=3, origin="o3")], 55, FRESH, C)
t = get_track(con, "META")
assert t and t["status"] == "conflict" and t["conviction"] == 70.0, t
assert "T8" in transitions(con, "META")

# T8 on a candidate: comparable-rank bull+bear -> abstain, no entry
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10",
             [cluster("COIN", conviction=80, rank=2, origin="o1"),
              cluster("COIN", direction="bearish", conviction=80, rank=3, origin="o2")], 55, FRESH, C)
assert get_track(con, "COIN") is None
assert "T8" in transitions(con, "COIN")

# Candidate with a better-ranked bearish call: no entry
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10",
             [cluster("HOOD", conviction=80, rank=4, origin="o1"),
              cluster("HOOD", direction="bearish", conviction=80, rank=1, origin="o2")], 55, FRESH, C)
assert get_track(con, "HOOD") is None

# T4+T5: decay without signal eventually exits (growth 5%/day from 60 -> <20)
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-01", [cluster("INTC", conviction=60)], 55, FRESH, C)
for i in range(2, 28):
    sm.apply_run(con, f"r{i}", f"2026-07-{i:02d}", [], 55, FRESH, C)
t = get_track(con, "INTC")
assert t and t["status"] == "exited", t
assert "T5" in transitions(con, "INTC")

# T9: stale coverage freezes new entries but decay keeps running on held tickers
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("AMZN", conviction=70)], 55, FRESH, C)
stale = {"growth": False, "value": True, "dividends": True}
sm.apply_run(con, "r2", "2026-06-11", [cluster("NFLX", conviction=90, rank=1, origin="o2")], 55, stale, C)
assert get_track(con, "NFLX") is None
assert "T9" in transitions(con, "NFLX")
t = get_track(con, "AMZN")  # held ticker decayed (no signal for it), not frozen
assert t and t["conviction"] < 70, t

# persist_signals writes the v3 sentiment columns + back-compat strength bucket
con = fresh_con()
sm.apply_run(con, "r1", "2026-06-10", [cluster("NVDA", conviction=72.5)], 55, FRESH, C)
row = con.execute("SELECT model_conviction, capped_conviction, thesis_type, horizon, "
                  "justification, speakers, strength FROM signals WHERE ticker='NVDA'").fetchone()
assert row[0] == 72.5 and row[1] == 72.5 and row[2] == "catalyst" and row[3] == "months", row
assert json.loads(row[5])[0]["quotes"] == ["a verified quote"], row
assert row[6] == "strong", row  # >=70 -> strong

# legacy_conviction mapping used by recompute replay of pre-v3 rows
assert sm.legacy_conviction("strong", 3, C) == 70.0
assert sm.legacy_conviction("moderate", 3, C) == 50.0
assert sm.legacy_conviction("strong", 5, C) == 60.0  # rank-5 cap applies

print("state_machine v2: all scenarios passed")
