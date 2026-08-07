"""Deterministic guardrail engine implementing SPEC-state-machine.md v2 (sentiment analyst,
approved 2026-07-01: LLM conviction is authoritative; code enforces caps, smoothing, transitions).

Entry: apply_run(con, run_id, session_date, clusters, regime_score, coverage_fresh, cfg)
where clusters are VALIDATED dicts:
  {ticker, direction, model_conviction, conviction (rank-capped), thesis_type, horizon,
   justification, speakers, best_rank, origin_key, track_proposal, event_ids, claim}
Quote verification, rank capping, and origin derivation happen upstream (synthesize.validate);
this module never trusts an uncapped number and owns every state transition.
"""
import hashlib
import json

TRACKS = ("growth", "value", "dividends")

# Legacy (schema<=2) signals carry only strength; map to a conviction so recompute replay
# of pre-v3 history stays deterministic. Values chosen to reproduce comparable behavior:
# strong enters (>= default entry_conviction 60), moderate/weak do not on their own.
LEGACY_STRENGTH_CONVICTION = {"strong": 70.0, "moderate": 50.0, "weak": 30.0}


def strength_label(capped_conviction):
    """Back-compat display bucket for the existing app/email surfaces."""
    if capped_conviction >= 70:
        return "strong"
    if capped_conviction >= 40:
        return "moderate"
    return "weak"


def rank_cap(cfg, best_rank):
    caps = cfg["sentiment"]["rank_conviction_caps"]
    return float(caps.get(str(best_rank), caps.get("5", 60)))


def legacy_conviction(strength, best_rank, cfg):
    base = LEGACY_STRENGTH_CONVICTION.get(strength, 30.0)
    return min(base, rank_cap(cfg, best_rank))


def _audit(con, run_id, session_date, ticker, transition, detail):
    con.execute(
        "INSERT INTO transitions (run_id, session_date, ticker, transition, detail) VALUES (?,?,?,?,?)",
        (run_id, session_date, ticker, transition, json.dumps(detail, sort_keys=True)),
    )


def _best(clusters):
    """Deterministic strongest cluster: highest capped conviction, then best rank, then origin."""
    return max(clusters, key=lambda c: (c["conviction"], -c["best_rank"], c["origin_key"]))


def persist_signals(con, run_id, session_date, clusters):
    for c in clusters:
        sid = hashlib.sha256(f"{run_id}:{c['ticker']}:{c['origin_key']}".encode()).hexdigest()
        con.execute(
            "INSERT OR IGNORE INTO signals (signal_id, run_id, session_date, ticker, direction, "
            "strength, best_rank, origin_key, track_proposal, event_ids, model_conviction, "
            "capped_conviction, thesis_type, horizon, justification, speakers) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (sid, run_id, session_date, c["ticker"], c["direction"],
             strength_label(c["conviction"]), c["best_rank"], c["origin_key"],
             c["track_proposal"], json.dumps(c["event_ids"]),
             c.get("model_conviction", c["conviction"]), c["conviction"],
             c.get("thesis_type", "other"), c.get("horizon", "unspecified"),
             c.get("justification", ""), json.dumps(c.get("speakers", []))),
        )


def apply_run(con, run_id, session_date, clusters, regime_score, coverage_fresh, cfg):
    """All transitions for one debrief run. Caller wraps in a transaction."""
    persist_signals(con, run_id, session_date, clusters)
    scfg = cfg["sentiment"]
    alpha = float(scfg["ema_alpha"])
    bearish_mult = cfg["regime"]["bearish_entry_threshold_multiplier"] if regime_score < 40 else 1.0

    by_ticker = {}
    for c in clusters:
        by_ticker.setdefault(c["ticker"], []).append(c)

    held = {r[0]: dict(zip(("track", "status", "conviction"), r[1:])) for r in con.execute(
        "SELECT ticker, track, status, conviction FROM tracks WHERE status IN ('active','conflict')")}

    # --- held tickers: T3/T4/T5/T6/T7/T8 ---
    for ticker, info in held.items():
        todays = by_ticker.get(ticker, [])
        bull = [c for c in todays if c["direction"] == "bullish"]
        bear = [c for c in todays if c["direction"] == "bearish"]
        track_cfg = cfg["tracks"][info["track"]]
        conviction = info["conviction"]

        if bull and bear:  # conflict handling first
            gap = abs(min(c["best_rank"] for c in bull) - min(c["best_rank"] for c in bear))
            if gap < 2:  # T8 abstain
                con.execute("UPDATE tracks SET status='conflict' WHERE ticker=?", (ticker,))
                _audit(con, run_id, session_date, ticker, "T8",
                       {"reason": "comparable-rank conflict", "bull": len(bull), "bear": len(bear)})
                continue
            winner = "bull" if min(c["best_rank"] for c in bull) < min(c["best_rank"] for c in bear) else "bear"
            bull, bear = (bull, []) if winner == "bull" else ([], bear)
            _audit(con, run_id, session_date, ticker, "T7", {"winner": winner})

        # T6: trusted (rank<=2) high-conviction bearish call exits immediately
        strong_bear = [c for c in bear if c["best_rank"] <= 2
                       and c["conviction"] >= scfg["exit_bearish_conviction"]]
        if strong_bear:
            b = _best(strong_bear)
            con.execute("UPDATE tracks SET status='exited', exited_at=?, exit_reason='rank-override' WHERE ticker=?",
                        (session_date, ticker))
            _audit(con, run_id, session_date, ticker, "T6",
                   {"conviction": b["conviction"], "justification": b.get("justification", ""),
                    "evidence": [c["event_ids"] for c in strong_bear]})
            continue

        if bull:  # T3 sentiment update toward the strongest bullish analysis (EMA)
            b = _best(bull)
            conviction = min(95.0, (1 - alpha) * conviction + alpha * b["conviction"])
            con.execute("UPDATE tracks SET conviction=?, last_signal_at=?, status='active' WHERE ticker=?",
                        (conviction, session_date, ticker))
            _audit(con, run_id, session_date, ticker, "T3",
                   {"direction": "bullish", "target": b["conviction"],
                    "conviction": round(conviction, 2), "thesis_type": b.get("thesis_type", ""),
                    "n_speakers": len(b.get("speakers", []))})
        elif bear:  # bearish sentiment (below T6 bar) pulls conviction down proportionally
            b = _best(bear)
            conviction = max(0.0, (1 - alpha) * conviction - alpha * b["conviction"])
            con.execute("UPDATE tracks SET conviction=? WHERE ticker=?", (conviction, ticker))
            _audit(con, run_id, session_date, ticker, "T3",
                   {"direction": "bearish", "pull": b["conviction"],
                    "conviction": round(conviction, 2), "thesis_type": b.get("thesis_type", "")})
        else:  # T4 decay
            conviction *= (1 - track_cfg["decay_pct_per_trading_day"] / 100)
            con.execute("UPDATE tracks SET conviction=? WHERE ticker=?", (conviction, ticker))
            _audit(con, run_id, session_date, ticker, "T4", {"conviction": round(conviction, 2)})

        if conviction < cfg["tracks"][info["track"]]["exit_below_conviction"]:  # T5
            con.execute("UPDATE tracks SET status='exited', exited_at=?, exit_reason='decayed' WHERE ticker=?",
                        (session_date, ticker))
            _audit(con, run_id, session_date, ticker, "T5", {"conviction": round(conviction, 2)})

    # --- candidates: T1/T2/T8/T9 ---
    for ticker, todays in by_ticker.items():
        if ticker in held:
            continue
        proposals = [c["track_proposal"] for c in todays if c["track_proposal"] in TRACKS]
        if not proposals:
            continue
        track = max(set(proposals), key=proposals.count)
        track_cfg = cfg["tracks"][track]
        if not coverage_fresh.get(track, False):  # T9 freeze
            _audit(con, run_id, session_date, ticker, "T9", {"track": track, "frozen": True})
            continue
        bull = [c for c in todays if c["direction"] == "bullish"]
        bear = [c for c in todays if c["direction"] == "bearish"]
        if not bull:
            continue
        if bear:  # contested candidate: comparable ranks abstain; a better-ranked bear blocks entry
            gap = abs(min(c["best_rank"] for c in bull) - min(c["best_rank"] for c in bear))
            if gap < 2:
                _audit(con, run_id, session_date, ticker, "T8",
                       {"reason": "comparable-rank conflict on candidate", "entry": False})
                continue
            if min(c["best_rank"] for c in bear) < min(c["best_rank"] for c in bull):
                continue
        b = _best(bull)
        base_threshold = float(track_cfg["entry_conviction"])
        threshold = min(100.0, base_threshold * bearish_mult)
        if b["conviction"] >= threshold:  # T1 immediate entry (Ivo 2026-07-01)
            conviction = min(95.0, b["conviction"])
            con.execute(
                "INSERT OR REPLACE INTO tracks (ticker, track, status, conviction, entered_at, last_signal_at) "
                "VALUES (?,?,?,?,?,?)",
                (ticker, track, "active", conviction, session_date, session_date))
            _audit(con, run_id, session_date, ticker, "T1",
                   {"conviction": conviction, "model_conviction": b.get("model_conviction", b["conviction"]),
                    "thesis_type": b.get("thesis_type", ""), "horizon": b.get("horizon", ""),
                    "justification": b.get("justification", "")[:300],
                    "n_speakers": len(b.get("speakers", [])), "regime": regime_score, "track": track})
        elif regime_score < 40 and b["conviction"] >= base_threshold:
            _audit(con, run_id, session_date, ticker, "T2",
                   {"note": "met base conviction threshold but bearish regime raised it",
                    "conviction": b["conviction"], "threshold": threshold})
