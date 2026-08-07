"""Validation-layer tests for synthesize.py v2 (sentiment analyst): quote verification,
rank caps, enum coercion, hallucinated-evidence rejection. Run: python3 tests/test_synthesize_validate.py
No codex/network involved — validate() is pure (payload, con, cfg) -> clusters."""
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))
import store
import synthesize as sz

PASS, FAIL = [], []


def check(name, cond):
    (PASS if cond else FAIL).append(name)
    print(("  ok  " if cond else " FAIL ") + name)


def cfg():
    with open(os.path.join(ROOT, "config.json")) as f:
        return json.load(f)


def con_with_events():
    con = sqlite3.connect(":memory:")
    con.executescript(store.DDL)
    rows = [
        ("ev1", 3, "x_tier1", "sunxliao",
         "I just bought more NVDA. Blackwell demand is insane and Q3 guidance will crush estimates."),
        ("ev2", 5, "x_tier2", "mikealfred",
         "NVDA to the moon!!! trust me bro this is the one"),
        ("ev3", 2, "tradingview", "alert",
         "NVDA weekly Arch signal confirmed, momentum regime intact per the suite rules."),
    ]
    for eid, rank, source, author, text in rows:
        con.execute(
            "INSERT INTO events (event_id, schema_version, ts, ingested_at, session_date, source, "
            "rank, author, type, text) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (eid, 1, "2026-06-30T12:00:00+00:00", "2026-06-30T12:00:00+00:00", "2026-06-30",
             source, rank, author, "post", text))
    return con


def payload(clusters):
    return {"clusters": clusters,
            "debrief": {"headline": "h", "market_summary": "s", "by_rank": [], "watch_notes": "w"}}


def base_cluster(**over):
    c = {"ticker": "NVDA", "direction": "bullish", "conviction": 85,
         "thesis_type": "catalyst", "horizon": "months", "track_proposal": "growth",
         "claim": "Blackwell demand beats guidance", "justification": "speaker has a position",
         "event_ids": ["ev1"],
         "speakers": [{"event_ids": ["ev1"], "sentiment": 90, "speaker_conviction": 90,
                       "position_disclosed": True, "hedged": False,
                       "quotes": ["I just bought more NVDA"]}]}
    c.update(over)
    return c


C = cfg()
con = con_with_events()

# 1. verified quote passes; cluster survives with raw + capped conviction (rank 3 cap = 80)
clusters, _ = sz.validate(payload([base_cluster()]), con, C)
check("verified quote: cluster survives", len(clusters) == 1)
check("rank cap: model 85 capped to 80 for best_rank 3",
      clusters and clusters[0]["model_conviction"] == 85.0 and clusters[0]["conviction"] == 80.0)

# 2. hallucinated quote -> speaker dropped -> cluster dropped
bad = base_cluster(speakers=[{"event_ids": ["ev1"], "sentiment": 90, "speaker_conviction": 90,
                              "quotes": ["NVDA is going bankrupt tomorrow says the CEO"]}])
clusters, _ = sz.validate(payload([bad]), con, C)
check("hallucinated quote: cluster dropped entirely", clusters == [])

# 3. quote cited against the WRONG event (text lives in ev2, cited ev1) -> dropped
wrong = base_cluster(speakers=[{"event_ids": ["ev1"], "quotes": ["trust me bro this is the one"],
                                "sentiment": 90, "speaker_conviction": 90}])
clusters, _ = sz.validate(payload([wrong]), con, C)
check("quote from a different event than cited: dropped", clusters == [])

# 4. whitespace/case differences still verify (normalized matching)
ws = base_cluster(speakers=[{"event_ids": ["ev1"], "sentiment": 90, "speaker_conviction": 90,
                             "quotes": ["  i JUST   bought more nvda "]}])
clusters, _ = sz.validate(payload([ws]), con, C)
check("normalized quote (case/whitespace) verifies", len(clusters) == 1)

# 5. trivially short quote (< MIN_QUOTE_CHARS) does not count as verification
tiny = base_cluster(speakers=[{"event_ids": ["ev1"], "sentiment": 90, "speaker_conviction": 90,
                               "quotes": ["NVDA"]}])
clusters, _ = sz.validate(payload([tiny]), con, C)
check("too-short quote rejected", clusters == [])

# 6. invented event_ids -> cluster dropped
fake = base_cluster(event_ids=["not-a-real-event"],
                    speakers=[{"event_ids": ["not-a-real-event"], "quotes": ["I just bought more NVDA"],
                               "sentiment": 90, "speaker_conviction": 90}])
clusters, _ = sz.validate(payload([fake]), con, C)
check("invented event_ids: cluster dropped", clusters == [])

# 7. conviction out of bounds is clamped, not fatal
hot = base_cluster(conviction=250, event_ids=["ev3"],
                   speakers=[{"event_ids": ["ev3"], "sentiment": 90, "speaker_conviction": 90,
                              "quotes": ["weekly Arch signal confirmed"]}])
clusters, _ = sz.validate(payload([hot]), con, C)
check("conviction clamped to 100 then rank-capped (rank 2 cap 95)",
      clusters and clusters[0]["model_conviction"] == 100.0 and clusters[0]["conviction"] == 95.0)

# 8. bad enums coerce to defaults rather than dying
weird = base_cluster(thesis_type="astrology", horizon="eons")
clusters, _ = sz.validate(payload([weird]), con, C)
check("bad thesis/horizon coerced to other/unspecified",
      clusters and clusters[0]["thesis_type"] == "other" and clusters[0]["horizon"] == "unspecified")

# 9. non-numeric conviction raises (triggers the retry/degraded path)
try:
    sz.validate(payload([base_cluster(conviction="very high")]), con, C)
    check("non-numeric conviction raises", False)
except ValueError:
    check("non-numeric conviction raises", True)

# 10. denylisted / malformed tickers still dropped
dl = base_cluster(ticker="AI")
clusters, _ = sz.validate(payload([dl]), con, C)
check("denylisted ticker dropped", clusters == [])

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    sys.exit(1)
print("synthesize validate v2: all tests pass")
