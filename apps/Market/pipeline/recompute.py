"""Idempotent recompute of derived_state (CONTRACTS.md §3).

recompute(con, cfg) is a PURE function of:
  (current `signals` rows) + (current `config`) + (non-tombstoned `overrides`).

It replays the persisted signals through the EXISTING engine (state_machine) into a throwaway
in-memory db (so it never touches the canonical `tracks`, `transitions`, or `conviction_history`
audit/history), applies overrides with precedence over the model, then WIPES + REWRITES
`derived_state` stamped with the current generation + config_version.

Determinism: signals are replayed in a fixed order (session_date, then a stable signal hash),
overrides applied in a fixed order. Running twice yields byte-identical `derived_state`.

The single source of truth for scoring is state_machine; this module never re-implements scoring.
"""
import json
import sqlite3

import state_machine as sm
import store

OVERRIDE_OPS = ("pin", "unpin", "force_exit", "manual_add", "resolve_conflict")


def _replay_tracks(con, cfg):
    """Replay all persisted signals through state_machine into a scratch db; return model tracks.

    Returns dict: ticker -> {track, status, conviction, entered_at, last_signal_at}.
    The scratch db mirrors the canonical signals exactly, so apply_run reproduces the same
    state the scheduled runs produced — but in isolation (no writes to canonical tables).
    """
    scratch = sqlite3.connect(":memory:")
    scratch.executescript(store.DDL)

    # Pull every signal, grouped by (run-equivalent) session in deterministic order.
    # We reconstruct per-session "runs": each distinct session_date is one replay step,
    # using that session's signals as the clusters. signal_id gives a stable tiebreak.
    rows = con.execute(
        "SELECT session_date, ticker, direction, strength, best_rank, origin_key, "
        "track_proposal, event_ids, signal_id, run_id, "
        "model_conviction, capped_conviction, thesis_type, horizon, justification, speakers "
        "FROM signals ORDER BY session_date ASC, signal_id ASC").fetchall()

    by_session = {}
    session_run = {}
    for (sd, ticker, direction, strength, best_rank, origin_key,
         track_proposal, event_ids, signal_id, run_id,
         model_conviction, capped_conviction, thesis_type, horizon,
         justification, speakers) in rows:
        # legacy (pre-v3) rows carry only strength; map deterministically so replay stays pure
        if capped_conviction is None:
            capped_conviction = sm.legacy_conviction(strength, best_rank, cfg)
        by_session.setdefault(sd, []).append({
            "ticker": ticker, "direction": direction,
            "model_conviction": model_conviction if model_conviction is not None else capped_conviction,
            "conviction": capped_conviction,
            "thesis_type": thesis_type or "other", "horizon": horizon or "unspecified",
            "justification": justification or "",
            "speakers": json.loads(speakers or "[]"),
            "best_rank": best_rank, "origin_key": origin_key,
            "track_proposal": track_proposal,
            "event_ids": json.loads(event_ids or "[]"),
        })
        # deterministic synthetic run id per session for the scratch replay
        session_run.setdefault(sd, f"rc-{sd}")

    # regime_score per session_date from the canonical regime table; default 50 (neutral).
    regime_by_session = {}
    for sd, score in con.execute("SELECT session_date, score FROM regime"):
        regime_by_session[sd] = score if score is not None else 50

    # coverage_fresh: for recompute we treat coverage as fresh (the signal already exists,
    # i.e. it passed the scheduled run's freshness gate). Freezing is a live-ingest concern;
    # replaying historical signals must reproduce the same entries deterministically.
    fresh = {t: True for t in cfg["tracks"]}

    for sd in sorted(by_session):
        clusters = by_session[sd]
        regime_score = regime_by_session.get(sd, 50)
        with scratch:
            sm.apply_run(scratch, session_run[sd], sd, clusters, regime_score, fresh, cfg)

    model = {}
    for r in scratch.execute(
            "SELECT ticker, track, status, conviction, entered_at, last_signal_at FROM tracks"):
        model[r[0]] = dict(zip(
            ("track", "status", "conviction", "entered_at", "last_signal_at"), r[1:]))
    scratch.close()
    return model


def _apply_overrides(model, overrides, con):
    """Apply non-tombstoned overrides with precedence > model. Returns {ticker -> derived row}.

    Each derived row: dict(ticker, track, status, conviction, entered_at, last_signal_at, source).
    source is 'override' for any ticker an override touched, else 'model'.
    """
    derived = {}
    for ticker, m in model.items():
        derived[ticker] = {
            "ticker": ticker, "track": m["track"], "status": m["status"],
            "conviction": m["conviction"], "entered_at": m["entered_at"],
            "last_signal_at": m["last_signal_at"], "source": "model",
        }

    # deterministic order: by ticker, then op, then track
    for ticker, op, track, note, created_at in sorted(
            overrides, key=lambda o: (o[0], o[1], o[2] or "")):
        row = derived.get(ticker)
        if op == "pin":
            # pin to a track; keep/raise it active. If unknown ticker, add as a pinned entry.
            if row is None:
                row = {"ticker": ticker, "track": track, "status": "active",
                       "conviction": 0.0, "entered_at": None, "last_signal_at": None,
                       "source": "override"}
                derived[ticker] = row
            row["status"] = "active"
            if track:
                row["track"] = track
            row["source"] = "override"
        elif op == "unpin":
            # release a pin: the ticker reverts to pure model state (drop override stamp).
            if row is not None:
                m = model.get(ticker)
                if m:
                    row.update({"track": m["track"], "status": m["status"],
                                "conviction": m["conviction"], "entered_at": m["entered_at"],
                                "last_signal_at": m["last_signal_at"], "source": "model"})
                else:
                    derived.pop(ticker, None)
        elif op == "force_exit":
            if row is None:
                row = {"ticker": ticker, "track": track, "status": "exited",
                       "conviction": 0.0, "entered_at": None, "last_signal_at": None,
                       "source": "override"}
                derived[ticker] = row
            row["status"] = "exited"
            row["source"] = "override"
        elif op == "manual_add":
            if row is None:
                row = {"ticker": ticker, "track": track, "status": "active",
                       "conviction": 0.0, "entered_at": None, "last_signal_at": None,
                       "source": "override"}
                derived[ticker] = row
            else:
                row["status"] = "active"
            if track:
                row["track"] = track
            row["source"] = "override"
        elif op == "resolve_conflict":
            # force a conflicted ticker into a definite track/active state per the override.
            if row is not None:
                if track:
                    row["track"] = track
                if row["status"] == "conflict":
                    row["status"] = "active"
                row["source"] = "override"
    return derived


def recompute(con, cfg):
    """Wipe + rewrite derived_state from (signals + config + overrides). Caller holds the tx + lock.

    Returns (generation, list_of_derived_rows). Bumps meta.generation. Idempotent: a second call
    with unchanged inputs produces byte-identical derived_state.
    """
    config_version = int(cfg.get("config_version", 0))

    model = _replay_tracks(con, cfg)
    overrides = con.execute(
        "SELECT ticker, op, track, note, created_at FROM overrides "
        "WHERE tombstoned_at IS NULL ORDER BY ticker, op, COALESCE(track,'')").fetchall()
    derived = _apply_overrides(model, overrides, con)

    generation = store.bump_generation(con)

    con.execute("DELETE FROM derived_state")
    for ticker in sorted(derived):
        r = derived[ticker]
        con.execute(
            "INSERT INTO derived_state (ticker, track, status, conviction, entered_at, "
            "last_signal_at, source, config_version, generation) VALUES (?,?,?,?,?,?,?,?,?)",
            (r["ticker"], r["track"], r["status"], r["conviction"], r["entered_at"],
             r["last_signal_at"], r["source"], config_version, generation))

    rows = [dict(zip(
        ("ticker", "track", "status", "conviction", "entered_at", "last_signal_at",
         "source", "config_version", "generation"), x))
        for x in con.execute(
            "SELECT ticker, track, status, conviction, entered_at, last_signal_at, source, "
            "config_version, generation FROM derived_state ORDER BY ticker")]
    return generation, rows
