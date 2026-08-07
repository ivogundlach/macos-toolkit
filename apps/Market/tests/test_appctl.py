"""Backend tests for the Market app-control layer (CONTRACTS.md §1-§5).

Run: venv/bin/python tests/test_appctl.py

Each test runs in an isolated sandbox (temp dir) with a COPY of the real db + config, so the
real state/market.sqlite and config.json are never mutated. Module globals that hold absolute
paths (store.ROOT, migrate.ROOT, appctl paths, util.LOCK_PATH) are repointed at the sandbox.

Covers:
  1. recompute idempotency        — run twice -> identical derived_state.
  2. set-config staged promote     — config + derived_state change on success.
  2b. set-config rollback          — forced recompute failure leaves config + db unchanged.
  3. override precedence           — force_exit / pin survives recompute.
  4. migration apply + integrity   — migrate a copy of the real db, integrity_check ok.
  5. notification outbox dedup     — same event id enqueued twice -> one row.
  6. blank account position upsert — no-account positions update one row, no NULL dupes.
"""
import json
import os
import shutil
import sqlite3
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))

import store
import migrate
import util
import appctl
import recompute as rc
import notifications as notif

REAL_DB = os.path.join(ROOT, "state", "market.sqlite")
REAL_CFG = os.path.join(ROOT, "config.json")

PASS = []
FAIL = []


def check(name, cond):
    (PASS if cond else FAIL).append(name)
    print(("  ok  " if cond else " FAIL ") + name)


class Sandbox:
    """Temp ROOT with a migrated copy of the real db + config; repoints module path globals."""

    def __enter__(self):
        self.dir = tempfile.mkdtemp(prefix="market-test-")
        os.makedirs(os.path.join(self.dir, "state", "backups"))
        self.db = os.path.join(self.dir, "state", "market.sqlite")
        self.cfg = os.path.join(self.dir, "config.json")
        shutil.copy(REAL_DB, self.db)
        shutil.copy(REAL_CFG, self.cfg)
        # snapshot + repoint module globals
        self._saved = {
            (store, "ROOT"): store.ROOT, (migrate, "ROOT"): migrate.ROOT,
            (util, "ROOT"): util.ROOT, (util, "LOCK_PATH"): util.LOCK_PATH,
            (appctl, "ROOT"): appctl.ROOT, (appctl, "CONFIG_PATH"): appctl.CONFIG_PATH,
            (appctl, "ARCHIVE_DIR"): appctl.ARCHIVE_DIR,
            (appctl, "LOCK_PATH"): appctl.LOCK_PATH, (appctl, "LOCK_META_PATH"): appctl.LOCK_META_PATH,
        }
        store.ROOT = migrate.ROOT = util.ROOT = appctl.ROOT = self.dir
        util.LOCK_PATH = os.path.join(self.dir, "state", ".run.lock")
        appctl.CONFIG_PATH = self.cfg
        appctl.ARCHIVE_DIR = os.path.join(self.dir, "state", "config_archive")
        appctl.LOCK_PATH = util.LOCK_PATH
        appctl.LOCK_META_PATH = util.LOCK_PATH + ".meta"
        # config() reads ROOT/config.json -> already repointed via store.ROOT
        con = store.connect()  # migrates the copy to v2
        con.close()
        return self

    def __exit__(self, *exc):
        for (mod, attr), val in self._saved.items():
            setattr(mod, attr, val)
        shutil.rmtree(self.dir, ignore_errors=True)

    def derived(self):
        con = sqlite3.connect(self.db)
        rows = con.execute(
            "SELECT ticker, track, status, conviction, entered_at, last_signal_at, source, "
            "config_version FROM derived_state ORDER BY ticker").fetchall()
        con.close()
        return rows

    def read_cfg(self):
        with open(self.cfg) as f:
            return json.load(f)


# ---- 1. recompute idempotency ----
def test_recompute_idempotent():
    with Sandbox() as sb:
        r1 = json.loads(_call("recompute", {}))
        d1 = sb.derived()
        r2 = json.loads(_call("recompute", {}))
        d2 = sb.derived()
        check("recompute idempotency: derived_state byte-identical across two runs", d1 == d2)
        check("recompute idempotency: generation strictly increases",
              r2["generation"] > r1["generation"])
        check("recompute idempotency: status ok", r1["status"] == "ok" and r2["status"] == "ok")


# ---- 2 / 2b. set-config staged promote + rollback ----
def test_set_config_promote_and_rollback():
    with Sandbox() as sb:
        before_cfg = sb.read_cfg()
        before_v = before_cfg["config_version"]
        before_derived = sb.derived()

        # 2b: FORCE recompute failure -> config + db unchanged
        try:
            appctl.run("set-config", {"path": "rank_weights.5", "value": 0.99},
                       _test_fail_recompute=True)
            failed = False
        except appctl.AppError:
            failed = True
        after_cfg = sb.read_cfg()
        check("set-config rollback: recompute failure raised", failed)
        check("set-config rollback: config.json unchanged on failure", after_cfg == before_cfg)
        check("set-config rollback: derived_state unchanged on failure",
              sb.derived() == before_derived)

        # 2: SUCCESSFUL set-config -> version bumps, config promoted, archive written
        out = json.loads(_call("set-config", {"path": "rank_weights.5", "value": 0.99}))
        promoted = sb.read_cfg()
        check("set-config promote: status ok", out["status"] == "ok")
        check("set-config promote: config_version bumped",
              promoted["config_version"] == before_v + 1)
        check("set-config promote: value applied to config.json",
              promoted["rank_weights"]["5"] == 0.99)
        archive_dir = os.path.join(sb.dir, "state", "config_archive")
        check("set-config promote: prior config archived",
              os.path.isdir(archive_dir) and len(os.listdir(archive_dir)) == 1)
        check("set-config promote: derived_state stamped with new config_version",
              all(r[7] == before_v + 1 for r in sb.derived()))


# ---- 3. override precedence survives recompute ----
def test_override_precedence():
    with Sandbox() as sb:
        # seed one v3 signal that clears the sentiment-v2 entry bar (capped conviction >= 60),
        # so an active model ticker exists regardless of what the copied real db contains
        con = store.connect()
        with con:
            con.execute(
                "INSERT OR REPLACE INTO signals (signal_id, run_id, session_date, ticker, "
                "direction, strength, best_rank, origin_key, track_proposal, event_ids, "
                "model_conviction, capped_conviction, thesis_type, horizon, justification, speakers) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                ("ovrseed", "seedrun", "2026-06-20", "OVRT", "bullish", "strong", 2,
                 "x_tier1:seed", "growth", "[]", 80.0, 80.0, "catalyst", "months",
                 "seed for override test", "[]"))
        con.close()
        json.loads(_call("recompute", {}))
        # pick a currently-active model ticker
        active = [r[0] for r in sb.derived() if r[2] == "active" and r[6] == "model"]
        assert active, "fixture has no active model tickers to override"
        tk = active[0]
        out = json.loads(_call("override", {"op": "force_exit", "ticker": tk}))
        check("override: force_exit returns override object", "override" in out["data"])
        row = next((r for r in sb.derived() if r[0] == tk), None)
        check("override: ticker is exited + source=override after override",
              row is not None and row[2] == "exited" and row[6] == "override")
        # recompute again — override must survive
        json.loads(_call("recompute", {}))
        row2 = next((r for r in sb.derived() if r[0] == tk), None)
        check("override precedence: still exited + override after a bare recompute",
              row2 is not None and row2[2] == "exited" and row2[6] == "override")

        # pin a brand-new ticker
        json.loads(_call("override", {"op": "manual_add", "ticker": "ZZTEST", "track": "value"}))
        json.loads(_call("recompute", {}))
        z = next((r for r in sb.derived() if r[0] == "ZZTEST"), None)
        check("override: manual_add introduces a ticker that survives recompute",
              z is not None and z[1] == "value" and z[2] == "active" and z[6] == "override")


# ---- 4. migration apply on a copy of the real db + integrity ----
def test_migration_apply_integrity():
    tmp = tempfile.mkdtemp(prefix="market-migr-")
    try:
        # fake a pristine v1 db: copy real db, drop the v2 tables + meta
        db = os.path.join(tmp, "market.sqlite")
        shutil.copy(REAL_DB, db)
        con = sqlite3.connect(db)
        for t in ("meta", "derived_state", "overrides", "positions", "watchlists",
                  "conviction_history", "notifications", "position_quotes"):
            con.execute(f"DROP TABLE IF EXISTS {t}")
        con.commit()
        check("migration: starts at schema 1 (v1 db)", migrate.get_schema_version(con) == 1)
        ev_before = con.execute("SELECT COUNT(*) FROM events").fetchone()[0]

        # repoint backup dir into the sandbox so it doesn't litter the real tree
        saved_root = migrate.ROOT
        migrate.ROOT = tmp
        os.makedirs(os.path.join(tmp, "state", "backups"), exist_ok=True)
        try:
            v = migrate.ensure_schema(con, db)
        finally:
            migrate.ROOT = saved_root

        check("migration: reaches code schema", v == migrate.CODE_SCHEMA)
        check("migration: integrity_check ok",
              con.execute("PRAGMA integrity_check").fetchone()[0] == "ok")
        check("migration: existing events preserved",
              con.execute("SELECT COUNT(*) FROM events").fetchone()[0] == ev_before)
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        need = {"meta", "derived_state", "overrides", "positions", "watchlists",
                "conviction_history", "notifications", "position_quotes"}
        check("migration: all v2 tables created", need.issubset(tables))
        # pre-migration backup exists + verifies
        backups = os.listdir(os.path.join(tmp, "state", "backups"))
        bkp = [b for b in backups if b.endswith(".sqlite")]
        check("migration: pre-migration backup written", len(bkp) == 1)
        bc = sqlite3.connect(os.path.join(tmp, "state", "backups", bkp[0]))
        check("migration: backup integrity_check ok",
              bc.execute("PRAGMA integrity_check").fetchone()[0] == "ok")
        check("migration: backup row count matches source",
              bc.execute("SELECT COUNT(*) FROM events").fetchone()[0] == ev_before)
        bc.close()
        con.close()

        # refuse-if-newer gate
        con2 = sqlite3.connect(db)
        migrate._set_meta(con2, "schema_version", migrate.MAX_SCHEMA + 1)
        con2.commit()
        try:
            migrate.ensure_schema(con2, db)
            refused = False
        except RuntimeError:
            refused = True
        check("migration: refuses db schema > code max_supported", refused)
        con2.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- 5. notification outbox dedup ----
def test_notification_dedup():
    with Sandbox() as sb:
        con = sqlite3.connect(sb.db)
        with con:
            con.execute("DELETE FROM notifications")  # copied real db may hold live rows
            i1 = notif.enqueue(con, "debrief_ready", None, "runX", "body")
            i2 = notif.enqueue(con, "debrief_ready", None, "runX", "body")  # dup
            notif.enqueue(con, "track_entry", "NVDA", "runX", "NVDA entered")
        check("notification dedup: same (kind,ticker,run_id) -> identical id", i1 == i2)
        n = con.execute("SELECT COUNT(*) FROM notifications").fetchone()[0]
        check("notification dedup: two unique events -> two rows (dup ignored)", n == 2)
        pend = con.execute("SELECT COUNT(*) FROM notifications WHERE state='pending'").fetchone()[0]
        check("notification dedup: both rows pending", pend == 2)
        con.close()

        # notify-claim/notify-ack: the app's delivery path (email retired 2026-07-01)
        out = json.loads(_call("notify-claim", {}))
        claimed = out["data"]["notifications"]
        check("notify-claim: returns both pending rows", len(claimed) == 2)
        con = sqlite3.connect(sb.db)
        states = {r[0] for r in con.execute("SELECT state FROM notifications")}
        check("notify-claim: rows moved to delivering with a lease", states == {"delivering"})
        con.close()
        out2 = json.loads(_call("notify-claim", {}))
        check("notify-claim: second claim returns nothing (lease held)",
              out2["data"]["notifications"] == [])
        ids = [c["id"] for c in claimed]
        out3 = json.loads(_call("notify-ack", {"ids": ids}))
        check("notify-ack: acks both claimed rows", out3["data"]["acked"] == 2)
        con = sqlite3.connect(sb.db)
        states = {r[0] for r in con.execute("SELECT state FROM notifications")}
        check("notify-ack: rows delivered", states == {"delivered"})
        con.close()
        out4 = json.loads(_call("notify-ack", {"ids": ids}))
        check("notify-ack: re-ack is a no-op (idempotent)", out4["data"]["acked"] == 0)


def test_position_blank_account_upsert():
    with Sandbox() as sb:
        out1 = json.loads(_call("position-set", {
            "symbol": "ZZDUP", "quantity": "1", "provenance": "manual"}))
        out2 = json.loads(_call("position-set", {
            "symbol": "ZZDUP", "quantity": "2", "provenance": "manual"}))
        con = sqlite3.connect(sb.db)
        rows = con.execute(
            "SELECT symbol, quantity, account, provenance FROM positions "
            "WHERE symbol='ZZDUP' ORDER BY id").fetchall()
        nulls = con.execute(
            "SELECT COUNT(*) FROM positions WHERE account IS NULL").fetchone()[0]
        con.close()
        check("position upsert: first blank-account save succeeds", out1["status"] == "ok")
        check("position upsert: second blank-account save succeeds", out2["status"] == "ok")
        check("position upsert: blank-account repeat updates one row, not two",
              rows == [("ZZDUP", "2", "", "manual")])
        check("position upsert: no NULL account values remain after position-set", nulls == 0)


def test_position_replace_atomic_edit():
    with Sandbox() as sb:
        original = json.loads(_call("position-set", {
            "symbol": "ZZOLD", "quantity": "1", "account": "", "provenance": "import"}))
        old_id = original["data"]["position"]["id"]
        replaced = json.loads(_call("position-replace", {
            "id": old_id, "symbol": "ZZNEW", "quantity": "2",
            "account": "taxable", "provenance": "manual"}))
        con = sqlite3.connect(sb.db)
        rows = con.execute(
            "SELECT id, symbol, quantity, account, provenance FROM positions "
            "WHERE symbol IN ('ZZOLD','ZZNEW') ORDER BY id").fetchall()
        con.close()
        check("position replace: status ok", replaced["status"] == "ok")
        check("position replace: preserves original id",
              replaced["data"]["position"]["id"] == old_id)
        check("position replace: edited row written in place atomically",
              rows == [(replaced["data"]["position"]["id"], "ZZNEW", "2", "taxable", "manual")])

        keep = json.loads(_call("position-set", {
            "symbol": "ZZKEEP", "quantity": "1", "account": "", "provenance": "manual"}))
        keep_id = keep["data"]["position"]["id"]
        try:
            appctl.run("position-replace", {"id": keep_id, "symbol": "ZZBAD"})
            failed = False
        except appctl.AppError:
            failed = True
        con = sqlite3.connect(sb.db)
        keep_rows = con.execute(
            "SELECT id, symbol, quantity, account, provenance FROM positions "
            "WHERE id=?", (keep_id,)).fetchall()
        con.close()
        check("position replace: invalid edit raises before deleting original", failed)
        check("position replace: original row remains after invalid edit",
              keep_rows == [(keep_id, "ZZKEEP", "1", "", "manual")])


def _call(cmd, args):
    """Invoke appctl.run() and serialize like the CLI would (one JSON object)."""
    return json.dumps(appctl.run(cmd, args))


if __name__ == "__main__":
    test_recompute_idempotent()
    test_set_config_promote_and_rollback()
    test_override_precedence()
    test_migration_apply_integrity()
    test_notification_dedup()
    test_position_blank_account_upsert()
    test_position_replace_atomic_edit()
    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        for f in FAIL:
            print("  FAILED:", f)
        sys.exit(1)
    print("appctl backend: all tests pass")
