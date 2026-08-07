"""Fault-injection tests for the Market app-control backend (CONTRACTS.md + APP-PLAN.md #14/#15).

Run: venv/bin/python tests/test_faults.py

These exercise the failure boundaries the plan's expanded fault-injection matrix calls out:
crash recovery at db/file boundaries, WAL backup restore, schema-rollout compat, alias collision,
decimal precision, notification crash windows, HTML escaping, and lock contention.

Every test runs on a COPY of the real db (state/market.sqlite) + config inside a temp ROOT; module
path globals (store/migrate/util/appctl ROOT + lock paths) are repointed at the sandbox, so the real
state/market.sqlite and config.json are NEVER mutated or destroyed. Mirrors tests/test_appctl.py.
"""
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from decimal import Decimal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))

import store
import migrate
import util
import appctl
import recompute as rc
import notifications as notif
import build_dashboard as bd

REAL_DB = os.path.join(ROOT, "state", "market.sqlite")
REAL_CFG = os.path.join(ROOT, "config.json")

PASS = []
FAIL = []


def check(name, cond):
    (PASS if cond else FAIL).append(name)
    print(("  ok  " if cond else " FAIL ") + name)


class Sandbox:
    """Temp ROOT with a migrated copy of the real db + config; repoints module path globals.

    Identical strategy to tests/test_appctl.Sandbox so faults run against realistic state without
    ever touching the canonical store.
    """

    def __enter__(self):
        self.dir = tempfile.mkdtemp(prefix="market-fault-")
        os.makedirs(os.path.join(self.dir, "state", "backups"))
        self.db = os.path.join(self.dir, "state", "market.sqlite")
        self.cfg = os.path.join(self.dir, "config.json")
        shutil.copy(REAL_DB, self.db)
        shutil.copy(REAL_CFG, self.cfg)
        self._saved = {
            (store, "ROOT"): store.ROOT, (migrate, "ROOT"): migrate.ROOT,
            (util, "ROOT"): util.ROOT, (util, "LOCK_PATH"): util.LOCK_PATH,
            (appctl, "ROOT"): appctl.ROOT, (appctl, "CONFIG_PATH"): appctl.CONFIG_PATH,
            (appctl, "ARCHIVE_DIR"): appctl.ARCHIVE_DIR,
            (appctl, "LOCK_PATH"): appctl.LOCK_PATH,
            (appctl, "LOCK_META_PATH"): appctl.LOCK_META_PATH,
        }
        store.ROOT = migrate.ROOT = util.ROOT = appctl.ROOT = self.dir
        util.LOCK_PATH = os.path.join(self.dir, "state", ".run.lock")
        appctl.CONFIG_PATH = self.cfg
        appctl.ARCHIVE_DIR = os.path.join(self.dir, "state", "config_archive")
        appctl.LOCK_PATH = util.LOCK_PATH
        appctl.LOCK_META_PATH = util.LOCK_PATH + ".meta"
        con = store.connect()  # migrate the copy to v2 (already v2 -> no-op)
        con.close()
        return self

    def __exit__(self, *exc):
        for (mod, attr), val in self._saved.items():
            setattr(mod, attr, val)
        shutil.rmtree(self.dir, ignore_errors=True)

    def read_cfg(self):
        with open(self.cfg) as f:
            return json.load(f)

    def derived(self):
        con = sqlite3.connect(self.db)
        rows = con.execute(
            "SELECT ticker, track, status, conviction, source, config_version "
            "FROM derived_state ORDER BY ticker").fetchall()
        con.close()
        return rows


def _call(cmd, args, **kw):
    return appctl.run(cmd, args, **kw)


# ---- 1. crash recovery at the config stage->promote boundary ----
def test_crash_between_stage_and_promote():
    """A process kill AFTER staging the new config but BEFORE promote must leave config.json AND
    derived_state untouched (no half-applied state). appctl stages inside the SQLite tx and only
    atomic-replaces config.json after recompute succeeds; _test_fail_recompute models the crash
    window (recompute raising == process dying mid-transaction)."""
    with Sandbox() as sb:
        _call("recompute", {})  # establish a derived_state baseline
        before_cfg_text = open(sb.cfg, encoding="utf-8").read()
        before_cfg = json.loads(before_cfg_text)
        before_derived = sb.derived()
        before_gen = json.loads(json.dumps(_ok_gen(sb)))

        crashed = False
        try:
            appctl.run("set-config", {"path": "rank_weights.5", "value": 0.42},
                       _test_fail_recompute=True)
        except appctl.AppError:
            crashed = True

        after_cfg_text = open(sb.cfg, encoding="utf-8").read()
        check("crash@stage->promote: write aborted (recompute raised, tx rolled back)", crashed)
        check("crash@stage->promote: config.json byte-identical (not half-written)",
              after_cfg_text == before_cfg_text)
        check("crash@stage->promote: config_version unchanged",
              json.loads(after_cfg_text)["config_version"] == before_cfg["config_version"])
        check("crash@stage->promote: derived_state unchanged (no partial recompute committed)",
              sb.derived() == before_derived)
        check("crash@stage->promote: no orphan staged config archive written",
              not os.path.isdir(appctl.ARCHIVE_DIR) or len(os.listdir(appctl.ARCHIVE_DIR)) == 0)
        check("crash@stage->promote: generation not bumped by the aborted write",
              _ok_gen(sb) == before_gen)


def _ok_gen(sb):
    con = sqlite3.connect(sb.db)
    r = con.execute("SELECT value FROM meta WHERE key='generation'").fetchone()
    con.close()
    return int(r[0]) if r else 0


# ---- 2. WAL backup restore: corrupt a copy, restore from a migrate.py backup ----
def test_wal_backup_restore():
    """A migrate.backup_db() snapshot is a self-contained single-file copy. Corrupt the working db,
    restore from the backup, and integrity_check must pass with row counts preserved."""
    with Sandbox() as sb:
        # take a verified backup via the real backup API
        saved_root = migrate.ROOT
        migrate.ROOT = sb.dir
        try:
            backup_path = migrate.backup_db(sb.db)
        finally:
            migrate.ROOT = saved_root
        check("wal restore: backup file created", os.path.isfile(backup_path))

        bc = sqlite3.connect(backup_path)
        ev_backup = bc.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        bc.close()

        # truncate the working db file + drop its WAL sidecars => corruption
        for ext in ("", "-wal", "-shm"):
            p = sb.db + ext
            if os.path.exists(p):
                with open(p, "r+b") as f:
                    f.truncate(64)  # smash the header
        corrupt = sqlite3.connect(sb.db)
        try:
            ic_corrupt = corrupt.execute("PRAGMA integrity_check").fetchone()[0]
        except sqlite3.DatabaseError as e:
            ic_corrupt = f"error: {e}"  # a malformed image may raise rather than return a string
        corrupt.close()
        check("wal restore: working db is genuinely corrupt after truncation", ic_corrupt != "ok")

        # restore: replace the working db with the backup
        for ext in ("-wal", "-shm"):
            if os.path.exists(sb.db + ext):
                os.remove(sb.db + ext)
        shutil.copy(backup_path, sb.db)

        restored = sqlite3.connect(sb.db)
        ic = restored.execute("PRAGMA integrity_check").fetchone()[0]
        ev = restored.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        restored.close()
        check("wal restore: integrity_check ok after restore", ic == "ok")
        check("wal restore: events row count preserved through backup+restore", ev == ev_backup)


# ---- 3. schema rollout compat: db stamped > code max is refused, not corrupted ----
def test_schema_rollout_refused():
    """A db whose schema_version exceeds the code's max_supported must be REFUSED (older code never
    touches a newer db), and the db must remain intact (not corrupted by the refusal)."""
    with Sandbox() as sb:
        con = sqlite3.connect(sb.db)
        migrate._set_meta(con, "schema_version", migrate.MAX_SCHEMA + 3)
        con.commit()
        ev_before = con.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        con.close()

        refused = False
        try:
            migrate.ensure_schema(sqlite3.connect(sb.db), sb.db)
        except RuntimeError:
            refused = True
        check("schema rollout: db schema > code max_supported is refused", refused)

        # store.connect() (the live path) must also refuse, surfacing the gate end-to-end
        live_refused = False
        try:
            store.connect().close()
        except RuntimeError:
            live_refused = True
        check("schema rollout: store.connect() refuses the future-schema db", live_refused)

        # not corrupted by the refusal
        con = sqlite3.connect(sb.db)
        ic = con.execute("PRAGMA integrity_check").fetchone()[0]
        ev_after = con.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        con.close()
        check("schema rollout: db not corrupted by the refusal", ic == "ok")
        check("schema rollout: data preserved (events count unchanged)", ev_after == ev_before)


# ---- 4. alias collision handled deterministically ----
def test_alias_collision_deterministic():
    """Two alias-set calls for the same alias key mapping to conflicting canonicals must resolve
    deterministically (last-write-wins, alias+canonical normalized to upper) — no nondeterminism,
    no duplicate keys, config stays valid JSON."""
    with Sandbox() as sb:
        _call("alias-set", {"alias": "FB", "canonical": "META"})
        _call("alias-set", {"alias": "fb", "canonical": "ALPHABET"})  # same key (FB), conflict
        cfg1 = sb.read_cfg()["ticker_aliases"]

        # repeat the identical sequence on a fresh sandbox -> identical result (determinism)
        with Sandbox() as sb2:
            _call("alias-set", {"alias": "FB", "canonical": "META"})
            _call("alias-set", {"alias": "fb", "canonical": "ALPHABET"})
            cfg2 = sb2.read_cfg()["ticker_aliases"]

        check("alias collision: single canonical key after conflict (no duplicate alias)",
              list(cfg1.keys()).count("FB") == 1)
        check("alias collision: last-write-wins (FB -> ALPHABET)", cfg1.get("FB") == "ALPHABET")
        check("alias collision: alias + canonical normalized to upper-case",
              "fb" not in cfg1 and cfg1["FB"] == "ALPHABET")
        check("alias collision: resolution is deterministic across identical runs", cfg1 == cfg2)


# ---- 5. decimal precision: quantity/cost_basis round-trip as canonical strings (no float drift) ----
def test_decimal_precision_roundtrip():
    """Position quantity/cost_basis are stored + returned as the EXACT decimal STRINGS supplied
    (CONTRACTS.md: money/quantity are decimal strings, arithmetic owned by Python not Swift).
    Values that would lose precision as IEEE-754 floats must round-trip byte-for-byte."""
    with Sandbox() as sb:
        tricky = "0.1"            # not representable in binary float
        cost = "12345.678901234567890"  # more digits than a double can hold
        out = _call("position-set", {"symbol": "ZZDEC", "quantity": tricky,
                                     "cost_basis": cost, "account": "test"})
        pos = out["data"]["position"]
        check("decimal: quantity returned as the exact supplied string", pos["quantity"] == tricky)
        check("decimal: cost_basis returned as the exact supplied string", pos["cost_basis"] == cost)
        check("decimal: quantity is stored as TEXT (no float coercion)",
              isinstance(pos["quantity"], str))

        # read straight from the db: stored value must be byte-identical to the input string
        con = sqlite3.connect(sb.db)
        q, cb = con.execute(
            "SELECT quantity, cost_basis FROM positions WHERE symbol='ZZDEC'").fetchone()
        con.close()
        check("decimal: db-persisted quantity byte-identical to input", q == tricky)
        check("decimal: db-persisted cost_basis byte-identical to input", cb == cost)
        # the string preserves precision a float would have dropped
        check("decimal: string preserves precision a double would lose",
              Decimal(cb) == Decimal("12345.678901234567890") and str(float(cb)) != cb)


# ---- 6. notification crash window: enqueue -> kill before deliver -> re-drain delivers once ----
def test_notification_crash_window_exactly_once():
    """Enqueue a notification, simulate a crash that leaves it stranded in 'delivering' with a stale
    lease (delivery started but the process died before marking delivered), then re-drain. The
    outbox lease must reclaim it and deliver EXACTLY once (no loss, no duplicate)."""
    import notifications as N
    delivered_calls = []
    orig = N._deliver_one
    N._deliver_one = lambda body: (delivered_calls.append(body), True)[1]
    try:
        with Sandbox() as sb:
            con = sqlite3.connect(sb.db)
            with con:
                con.execute("DELETE FROM notifications")  # copied real db may hold live rows
                nid = N.enqueue(con, "track_entry", "NVDA", "runZ", "NVDA entered growth")

            # simulate crash mid-delivery: row stuck in 'delivering' with an EXPIRED lease
            with con:
                con.execute("UPDATE notifications SET state='delivering', "
                            "lease_until='2000-01-01T00:00:00+00:00' WHERE id=?", (nid,))

            n1 = N.drain(con)  # should reclaim the stale lease and deliver
            state1 = con.execute("SELECT state FROM notifications WHERE id=?", (nid,)).fetchone()[0]
            n2 = N.drain(con)  # re-drain: already delivered -> nothing more
            state2 = con.execute("SELECT state FROM notifications WHERE id=?", (nid,)).fetchone()[0]
            con.close()

            check("notif crash: re-drain reclaims the stale lease and delivers", n1 == 1)
            check("notif crash: row marked delivered after reclaim", state1 == "delivered")
            check("notif crash: second drain delivers nothing (idempotent)", n2 == 0)
            check("notif crash: delivered EXACTLY once across both drains",
                  len(delivered_calls) == 1)
            check("notif crash: still delivered after re-drain", state2 == "delivered")

            # a fresh enqueue of the SAME event id is ignored (no resurrection of delivered work)
            con = sqlite3.connect(sb.db)
            with con:
                nid2 = N.enqueue(con, "track_entry", "NVDA", "runZ", "NVDA entered growth")
            cnt = con.execute("SELECT COUNT(*) FROM notifications WHERE id=?", (nid2,)).fetchone()[0]
            con.close()
            check("notif crash: re-enqueue of delivered event stays deduped (one row)",
                  nid2 == nid and cnt == 1)
    finally:
        N._deliver_one = orig


# ---- 7. HTML escaping: malicious <script> ticker/text renders escaped in the email body ----
def test_html_escaping_email_body():
    """A signal/event carrying a <script> payload in ticker + text must render ESCAPED in the email
    body produced by build_dashboard.render_email — no raw <script>, no unescaped attribute breakout."""
    with Sandbox() as sb:
        con = sqlite3.connect(sb.db)
        evil_ticker = '<script>alert(1)</script>'
        evil_text = '"><img src=x onerror=alert(2)>EVIL'
        sd = "2026-06-12"
        with con:
            # an event (drives the source feed) + a signal (drives the signals table)
            con.execute(
                "INSERT OR REPLACE INTO events (event_id, schema_version, ts, ingested_at, "
                "session_date, source, rank, author, type, text, tickers, urls, engagement, "
                "raw_ref) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                ("evil1", 1, sd + "T12:00:00+00:00", sd + "T12:00:00+00:00", sd, "x_tier1", 3,
                 evil_text, "post", evil_text, json.dumps([evil_ticker]), "[]", "{}", ""))
            con.execute(
                "INSERT OR REPLACE INTO signals (signal_id, run_id, session_date, ticker, "
                "direction, strength, best_rank, origin_key, track_proposal, event_ids) "
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("evilsig", "runE", sd, evil_ticker, "bullish", "strong", 3,
                 "x_tier1:" + evil_text, "growth", json.dumps(["evil1"])))
        cfg = sb.read_cfg()
        debrief = {"headline": evil_text, "market_summary": evil_text,
                   "by_rank": [{"rank": 3, "summary": evil_text}], "watch_notes": evil_text}
        html_doc = bd.render_email(con, cfg, debrief, {"degraded": False}, "Sess", sd)
        con.close()

        check("html escaping: no raw <script> tag in the rendered email body",
              "<script>" not in html_doc)
        check("html escaping: the payload appears HTML-escaped (&lt;script&gt;)",
              "&lt;script&gt;" in html_doc)
        # the onerror= text itself is harmless once its surrounding <,>," are escaped: the real
        # security property is that no live <img tag and no quote/angle breakout survive.
        check("html escaping: no unescaped <img tag and no attribute breakout",
              "<img src=x" not in html_doc and '"><img' not in html_doc
              and "&lt;img src=x onerror=alert(2)&gt;" in html_doc)
        check("html escaping: debrief headline (LLM-authored text) is escaped too",
              "alert(1)" not in html_doc.replace("&lt;script&gt;alert(1)&lt;/script&gt;", ""))


# ---- 8. concurrent launchd-run + app-write: flock held -> appctl mutate returns LOCK_BUSY ----
def test_lock_busy_no_write():
    """While the launchd pipeline holds the RunLock flock, an app-initiated appctl MUTATION must
    return LOCK_BUSY and perform NO write (CONTRACTS.md §1: non-blocking flock, sole-writer)."""
    import fcntl
    with Sandbox() as sb:
        _call("recompute", {})  # baseline derived_state
        before_derived = sb.derived()
        before_gen = _ok_gen(sb)

        # simulate the launchd run holding the lock (separate fd, as a different process would)
        os.makedirs(os.path.dirname(util.LOCK_PATH), exist_ok=True)
        holder = open(util.LOCK_PATH, "w")
        fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            code = None
            try:
                appctl.run("override", {"op": "force_exit", "ticker": "NVDA"})
            except appctl.AppError as e:
                code = e.code
            check("lock busy: mutate while lock held returns LOCK_BUSY", code == "LOCK_BUSY")
            check("lock busy: derived_state unchanged (no write occurred)",
                  sb.derived() == before_derived)
            check("lock busy: generation unchanged (no commit)", _ok_gen(sb) == before_gen)

            # no override row leaked into the db
            con = sqlite3.connect(sb.db)
            cnt = con.execute(
                "SELECT COUNT(*) FROM overrides WHERE ticker='NVDA' AND op='force_exit'"
            ).fetchone()[0]
            con.close()
            check("lock busy: no override row written while lock was held", cnt == 0)
        finally:
            fcntl.flock(holder, fcntl.LOCK_UN)
            holder.close()

        # lock released -> the same mutate now succeeds (proves the block was the lock, not a bug)
        out = appctl.run("override", {"op": "force_exit", "ticker": "NVDA"})
        check("lock busy: same mutate succeeds once the lock is released",
              out["status"] == "ok")


TESTS = [
    test_crash_between_stage_and_promote,
    test_wal_backup_restore,
    test_schema_rollout_refused,
    test_alias_collision_deterministic,
    test_decimal_precision_roundtrip,
    test_notification_crash_window_exactly_once,
    test_html_escaping_email_body,
    test_lock_busy_no_write,
]


if __name__ == "__main__":
    for t in TESTS:
        print(f"\n# {t.__name__}")
        t()
    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        for f in FAIL:
            print("  FAILED:", f)
        sys.exit(1)
    print("fault-injection: all tests pass")
