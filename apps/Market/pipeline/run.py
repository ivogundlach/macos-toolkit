"""Orchestrator. Two entry modes:

  python3 pipeline/run.py ingest    # adapters only (runs daily)
  python3 pipeline/run.py debrief   # gated by calendar; synth + state + dashboard + email

Commit protocol: a run row is created at start and 'committed' (content hash recorded) before
side effects (dashboard rename, email send). Side effects are retryable projections of the
committed run; email is at-most-once via send_email reconciliation.
"""
import hashlib
import json
import os
import subprocess
import sys
import traceback
from datetime import date, datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store
import util
import calendar_gate

def adapter_list(cfg):
    # X uses Playwright only (Firecrawl removed 2026-06-13: ~5-post cap, no scroll on plan).
    return ["market_regime.py", "x_playwright.py", "youtube_ytdlp.py",
            "tradingview_gmail.py", "discord_stub.py"]


def update_indicators(cfg):
    """Refresh the deterministic indicator-suite status plane (schema v5) from the
    freshly-ingested TradingView alert events. Independent of the LLM conviction
    machine; idempotent, so it's safe to call on every ingest and debrief run.
    Uses its own connection + transaction (runs after adapters, still under RunLock)."""
    try:
        import indicator_status as ind
        con = store.connect()
        try:
            with con:
                new, n = ind.update(con, cfg)
            util.log("run", f"indicator status: +{new} reads, {n} status rows")
        finally:
            con.close()
    except Exception as e:
        # never let the indicator plane fail a run; the debrief/ingest is authoritative
        util.log("run", f"indicator status update failed (non-fatal): {e}")


def run_adapters(cfg):
    results = {}
    for adapter in adapter_list(cfg):
        src = adapter.replace(".py", "")
        path = os.path.join(store.ROOT, "adapters", adapter)
        try:
            out = subprocess.run([sys.executable, path], capture_output=True, text=True, timeout=1200)
            results[src] = "ok" if out.returncode == 0 else f"rc={out.returncode}"
            if out.returncode != 0:
                util.log("run", f"{adapter} failed: {out.stderr[-200:]}")
        except Exception as e:
            results[src] = f"error:{e}"
            util.log("run", f"{adapter} exception: {e}")
    failed = {name: status for name, status in results.items() if status != "ok"}
    if failed:
        raise RuntimeError("adapter failure: " + ", ".join(
            f"{name}={status}" for name, status in sorted(failed.items())))
    return results


def coverage_fresh(con, cfg, session_date):
    """Per-track: are required sources fresh enough to allow new entries?"""
    fresh = {}
    for track, tcfg in cfg["tracks"].items():
        ok = True
        for src in tcfg["required_coverage"]:
            row = con.execute("SELECT MAX(ingested_at) FROM events WHERE source=?", (src,)).fetchone()
            if not row or not row[0]:
                ok = False
                break
            age_days = (datetime.now(timezone.utc) - datetime.fromisoformat(row[0])).days
            if (src == "regime" and age_days > 1) or (src != "regime" and age_days > 2):
                ok = False
                break
        fresh[track] = ok
    return fresh


DEBRIEF_STATUS_FILENAME = (
    "debrief_status.json"
    if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1"
    else "debrief_status.interactive.json"
)
DEBRIEF_STATUS_PATH = os.path.join(store.ROOT, "state", DEBRIEF_STATUS_FILENAME)


def write_debrief_status(status, **fields):
    """Publish debrief health for the Tool Status Dashboard.

    A degraded debrief still commits and still exits 0, so the dispatcher writes
    `debrief.last_success` and the daily stamp either way — the Dashboard cannot tell a
    synthesis failure from a healthy run through the stamp plane alone (Ivo, 2026-07-20).
    This sidecar is that missing signal, and follows the same contract as the adapter
    scraper-health files so the Dashboard reads all four the same way.

    Only the real debrief path writes here: on a non-debrief day `do_debrief` returns before
    this point, so an unrepaired `degraded` correctly persists until a debrief actually succeeds.
    """
    payload = {
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "execution_context": "background" if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1" else "interactive",
        "status": status,
        **fields,
    }
    temporary = DEBRIEF_STATUS_PATH + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, DEBRIEF_STATUS_PATH)


def degraded_debrief(con, session_date):
    """No-LLM fallback: list raw evidence so a run still ships something honest."""
    rows = con.execute(
        "SELECT rank, source, author, substr(text,1,160) FROM events WHERE source!='regime' "
        "ORDER BY rank, ts DESC LIMIT 40").fetchall()
    body = "\n".join(f"[r{r[0]}] {r[1]}/{r[2]}: {r[3]}" for r in rows)
    return {"headline": "DEGRADED debrief — synthesis unavailable, raw evidence only",
            "market_summary": "The synthesis engine did not return valid output. Raw source "
            "evidence is listed below; no recommendation changes were applied this run.",
            "by_rank": [], "watch_notes": body[:800]}


def ticker_summary(tickers, cap=5):
    """Compact ticker list for the one-line debrief banner: 'A, B, C +4'."""
    extra = len(tickers) - cap
    head = ", ".join(tickers[:cap])
    return f"{head} +{extra}" if extra > 0 else head


def do_debrief(cfg, force=False):
    today = date.today()
    fire, reason = calendar_gate.is_debrief_day(today)
    if not fire and not force:
        util.log("run", f"debrief skip — {reason}")
        return 0
    nxt = calendar_gate.next_session(today)
    session_label = f"Prep for {nxt.strftime('%a %b %-d, %Y')} (built {today.strftime('%a %b %-d')} {datetime.now().strftime('%H:%M')} local)"

    con = store.connect()
    import synthesize, state_machine as sm, notifications
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    watermark = con.execute("SELECT manifest FROM runs WHERE kind='debrief' AND committed_at IS NOT NULL "
                            "ORDER BY committed_at DESC LIMIT 1").fetchone()
    since = "1970-01-01T00:00:00+00:00"
    if watermark:
        since = json.loads(watermark[0]).get("watermark", since)
    new_watermark = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with con:
        con.execute("INSERT INTO runs (run_id, started_at, kind, watermark, manifest) VALUES (?,?,?,?,?)",
                    (run_id, new_watermark, "debrief", new_watermark,
                     json.dumps({"watermark": new_watermark})))

    regime = con.execute("SELECT score FROM regime ORDER BY session_date DESC LIMIT 1").fetchone()
    regime_score = regime[0] if regime and regime[0] is not None else 50
    degraded = False
    degraded_reason = ""
    try:
        clusters, debrief, meta = synthesize.synthesize(con, cfg, today.isoformat(), since)
    except Exception as e:
        util.log("run", f"synthesis failed, degrading: {e}")
        degraded_reason = str(e)[:400]
        clusters, debrief, meta, degraded = [], degraded_debrief(con, today.isoformat()), {"degraded": True}, True
    meta["degraded"] = degraded

    fresh = coverage_fresh(con, cfg, today.isoformat())
    import recompute as rc
    with con:
        if clusters:
            sm.apply_run(con, run_id, today.isoformat(), clusters, regime_score, fresh, cfg)
        # append immutable conviction_history for this scheduled run (keyed by ticker,run_id)
        for tk, track, conv in con.execute(
                "SELECT ticker, track, conviction FROM tracks WHERE status IN ('active','conflict')"):
            con.execute("INSERT OR IGNORE INTO conviction_history "
                        "(ticker, run_id, session_date, track, conviction) VALUES (?,?,?,?,?)",
                        (tk, run_id, today.isoformat(), track, conv))
        # enqueue the notification (transactional outbox; deterministic ids dedup across retries).
        # Delivery is the APP's job (Market.app polls `appctl notify-claim` and posts native
        # push notifications; Ivo 2026-07-01 — email delivery retired entirely).
        headline = debrief.get("headline", "")[:120]
        # Market.app posts CONTENT only (the debrief is ready, and what entered/exited a track).
        # A degraded debrief is a HEALTH failure, and the signed Tool Status Dashboard owns
        # unattended failure repair, deduplication, escalation, and push delivery — a banner
        # from here was a dead end with none of that (Ivo, 2026-07-20). The Dashboard picks it
        # up from `state/debrief_status.json`. The degraded headline still rides along on
        # `debrief_ready` below, so Ivo knows the debrief he is about to read is evidence-only.
        # When degraded, the synthesis headline is a failure message ("DEGRADED debrief —
        # synthesis unavailable"), and Market.app must not be the surface that reports a
        # failure. Ivo still needs to know the debrief he is about to open is thin, so the
        # banner says so plainly and leaves the diagnosis and repair to the Dashboard.
        # ONE notification per run (Ivo, 2026-07-23). Per-ticker track_entry/track_exit rows
        # used to fan a single synthesis out into ~10 banners; the entries and exits now ride
        # on the debrief_ready line, and the app remains the place to read the detail.
        entries, exits = [], []
        for tk, transition in con.execute(
                "SELECT ticker, transition FROM transitions WHERE run_id=? ORDER BY ticker",
                (run_id,)):
            if transition == "T1":  # high-conviction track ENTRY
                entries.append(tk)
            elif transition in ("T5", "T6"):  # track EXIT (decayed / rank-override)
                exits.append(tk)
        body = f"Debrief ready — prep for {nxt.strftime('%a %b %-d')}"
        for label, tickers in (("In", entries), ("Out", exits)):
            if tickers:
                body += f" · {label}: {ticker_summary(tickers)}"
        # The headline goes on its own line so the actionable track delta always survives
        # banner truncation; the full headline stays readable in Notification Center.
        if degraded:
            body += " (evidence only)"
        elif headline:
            body += f"\n{headline}"
        notifications.enqueue(con, "debrief_ready", None, run_id, body)
        # commit: record content hash before side effects
        content_hash = hashlib.sha256(json.dumps(debrief, sort_keys=True).encode()).hexdigest()
        con.execute("UPDATE runs SET committed_at=?, manifest=json_set(manifest,'$.content_hash',?,"
                    "'$.degraded',?,'$.n_clusters',?) WHERE run_id=?",
                    (datetime.now(timezone.utc).isoformat(timespec="seconds"), content_hash,
                     1 if degraded else 0, len(clusters), run_id))
        # persist the FULL debrief for the app (sole reading surface since 2026-07-01).
        # Never let a degraded rebuild clobber a good debrief already committed for this
        # session: a repair run that itself fails synthesis must leave the working debrief
        # intact rather than downgrade it to evidence-only.
        superseded = False
        if degraded:
            existing = con.execute(
                "SELECT debrief_json FROM runs_debrief WHERE session_date=?",
                (today.isoformat(),)).fetchone()
            if existing:
                try:
                    superseded = not json.loads(existing[0]).get("degraded", False)
                except (ValueError, TypeError):
                    superseded = False
        if superseded:
            util.log("run", f"debrief {run_id} degraded; keeping the existing non-degraded "
                            f"debrief for {today.isoformat()}")
        else:
            con.execute("INSERT OR REPLACE INTO runs_debrief (session_date, headline, debrief_json, run_id) "
                        "VALUES (?,?,?,?)",
                        (today.isoformat(), headline,
                         json.dumps({**debrief, "session_label": session_label,
                                     "degraded": degraded}, sort_keys=True), run_id))
        # refresh the app's live derived_state view from the new signals + overrides
        rc.recompute(con, cfg)

    # Health describes the debrief that is actually COMMITTED for this session, because that is
    # what a repair can act on. A failed rebuild that kept a good debrief reports ok (there is
    # nothing to repair, and re-running would only risk another failure) but still records the
    # synthesis error so the failure is not invisible.
    write_debrief_status(
        "degraded" if degraded and not superseded else "ok",
        session_date=today.isoformat(),
        run_id=run_id,
        n_clusters=len(clusters),
        **({"degraded_reason": degraded_reason} if degraded and not superseded else {}),
        **({"last_synthesis_error": degraded_reason} if degraded and superseded else {}),
    )

    util.log("run", f"debrief {run_id} done (degraded={degraded}, clusters={len(clusters)})")
    return 0


def main():
    cfg = store.config()
    mode = sys.argv[1] if len(sys.argv) > 1 else "debrief"
    force = "--force" in sys.argv
    try:
        with util.RunLock(mode):
            if mode == "ingest":
                results = run_adapters(cfg)
                update_indicators(cfg)       # refresh indicator-suite status plane
                util.log("run", f"ingest done: {results}")
            elif mode == "debrief":
                run_adapters(cfg)            # fresh data first
                update_indicators(cfg)       # refresh indicator-suite status plane
                do_debrief(cfg, force=force)
            elif mode == "recompute":
                # rebuild derived_state without adapters/codex (appctl is the app's entry point;
                # this exists so the pipeline can refresh the live view independently if useful)
                import recompute as rc
                con = store.connect()
                with con:
                    gen, rows = rc.recompute(con, cfg)
                util.log("run", f"recompute done: generation={gen}, {len(rows)} tracks")
            else:
                raise SystemExit(f"unknown mode {mode!r}")
        # lock released here — deliver enqueued notifications via the app's headless
        # drain mode (works with Market.app CLOSED; notify-claim needs the same flock)
        if mode == "debrief":
            try:
                import notifications
                notifications.deliver_via_app()
            except Exception as e:
                util.log("run", f"notify delivery failed (non-fatal, rows stay pending): {e}")
    except SystemExit:
        raise
    except Exception as e:
        util.log("run", f"FATAL {mode}: {e}\n{traceback.format_exc()}")
        # The signed Tool Status Dashboard owns unattended failure repair,
        # deduplication, and push delivery. The dispatcher preserves this nonzero
        # exit and detailed log evidence for its five-minute health scan.
        sys.exit(1)


if __name__ == "__main__":
    main()
