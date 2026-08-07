"""appctl — the SOLE writer CLI for the Market app (CONTRACTS.md §1).

Invocation (from Swift, no shell):
  venv/bin/python pipeline/appctl.py <cmd> --json '<args-json>'

stdout: exactly one JSON object:
  {status, code, generation, config_version, run_id, message?, data?}

Every MUTATING command: acquire flock RunLock non-blocking (LOCK_BUSY if held) -> validate ->
single SQLite transaction -> (config cmds: stage -> recompute -> promote-on-success ->
atomic-replace config.json -> archive prior) -> bump meta.generation -> commit -> emit one JSON.
READS (get-state, get-ticker, health) run lock-free (WAL).
"""
import fcntl
import json
import os
import stat
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store
import util
import recompute as rc

ROOT = store.ROOT
CONFIG_PATH = os.path.join(ROOT, "config.json")
ARCHIVE_DIR = os.path.join(ROOT, "state", "config_archive")
LOCK_PATH = util.LOCK_PATH
LOCK_META_PATH = LOCK_PATH + ".meta"

READ_CMDS = {"get-state", "get-ticker", "health"}
RECOMPUTE_CMDS = {"set-config", "override", "denylist-add", "denylist-remove",
                  "alias-set", "alias-delete"}
OVERRIDE_OPS = {"pin", "unpin", "force_exit", "manual_add", "resolve_conflict"}


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class AppError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# ---------------- lock (non-blocking, with metadata sidecar) ----------------

class AppLock:
    """Non-blocking flock; raises AppError(LOCK_BUSY) if held. flock is authoritative;
    the .meta sidecar is informational for health display (CONTRACTS.md §5)."""

    def __init__(self, cmd):
        self.cmd = cmd
        self.fh = None

    def __enter__(self):
        os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
        self.fh = open(LOCK_PATH, "w")
        try:
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.fh.close()
            self.fh = None
            raise AppError("LOCK_BUSY", f"another run holds {LOCK_PATH}")
        meta = {"pid": os.getpid(), "proc_start": _proc_start(os.getpid()),
                "cmd": self.cmd, "acquired_at": utc_now()}
        try:
            util.atomic_write(LOCK_META_PATH, json.dumps(meta))
        except OSError:
            pass
        return self

    def __exit__(self, *exc):
        if self.fh is not None:
            try:
                os.remove(LOCK_META_PATH)
            except OSError:
                pass
            fcntl.flock(self.fh, fcntl.LOCK_UN)
            self.fh.close()


def _proc_start(pid):
    try:
        return datetime.fromtimestamp(
            os.stat(f"/proc/{pid}").st_ctime, timezone.utc).isoformat(timespec="seconds")
    except OSError:
        return None  # macOS has no /proc; pid + acquired_at still identify the holder


def _lock_held():
    """Best-effort read of current lock holder (does not acquire). For health."""
    if not os.path.exists(LOCK_PATH):
        return {"held": False}
    fh = open(LOCK_PATH, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fh, fcntl.LOCK_UN)
        held = False
    except BlockingIOError:
        held = True
    finally:
        fh.close()
    meta = None
    if held and os.path.exists(LOCK_META_PATH):
        try:
            meta = json.loads(open(LOCK_META_PATH, encoding="utf-8").read())
        except (OSError, json.JSONDecodeError):
            meta = None
    return {"held": held, "meta": meta}


# ---------------- config staging / promote / archive ----------------

def _deep_set(obj, dotted, value):
    """Set config[a][b][c]=value from 'a.b.c'. Numeric segments index dicts keyed by str."""
    parts = dotted.split(".")
    cur = obj
    for p in parts[:-1]:
        if p not in cur:
            raise AppError("VALIDATION", f"config path segment not found: {p!r}")
        cur = cur[p]
    last = parts[-1]
    if isinstance(cur, dict):
        cur[last] = value
    else:
        raise AppError("VALIDATION", f"cannot set {dotted!r}: parent is not an object")


def _deep_merge(dst, patch):
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _deep_merge(dst[k], v)
        else:
            dst[k] = v


def _archive_config(prev_text, prev_version):
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(ARCHIVE_DIR, f"config-v{prev_version}-{ts}.json")
    util.atomic_write(path, prev_text)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    _prune_archives(50)
    return path


def _prune_archives(keep):
    if not os.path.isdir(ARCHIVE_DIR):
        return
    files = sorted(f for f in os.listdir(ARCHIVE_DIR) if f.endswith(".json"))
    for f in files[:-keep] if len(files) > keep else []:
        try:
            os.remove(os.path.join(ARCHIVE_DIR, f))
        except OSError:
            pass


def _apply_config_change(args, prev_cfg):
    """Return the new config dict (validated, version bumped). Does NOT write to disk yet."""
    new_cfg = json.loads(json.dumps(prev_cfg))  # deep copy
    if "patch" in args:
        if not isinstance(args["patch"], dict):
            raise AppError("VALIDATION", "patch must be an object")
        _deep_merge(new_cfg, args["patch"])
    elif "path" in args:
        if "value" not in args:
            raise AppError("VALIDATION", "set-config with path requires value")
        _deep_set(new_cfg, str(args["path"]), args["value"])
    else:
        raise AppError("VALIDATION", "set-config requires 'path'+'value' or 'patch'")
    new_cfg["config_version"] = int(prev_cfg.get("config_version", 0)) + 1
    return new_cfg


# ---------------- command handlers ----------------

def cmd_recompute(con, cfg, args):
    generation, rows = rc.recompute(con, cfg)
    return {"generation": generation, "tracks": rows}


def cmd_set_config(con, cfg, args, fail_recompute=False):
    """Stage -> recompute against staged config -> promote on success -> atomic replace + archive.

    The whole thing is inside one SQLite transaction (caller's `with con`). If recompute raises,
    the transaction rolls back and config.json is NEVER touched (config unchanged on failure).
    fail_recompute is a test hook to force a recompute failure.
    """
    prev_text = open(CONFIG_PATH, encoding="utf-8").read()
    prev_cfg = json.loads(prev_text)
    new_cfg = _apply_config_change(args, prev_cfg)

    if fail_recompute:
        raise AppError("INTERNAL", "forced recompute failure (test hook)")
    # recompute against the STAGED config (not yet on disk)
    generation, rows = rc.recompute(con, new_cfg)

    # promote: archive prior, then atomic-replace config.json
    new_text = json.dumps(new_cfg, indent=2)
    _archive_config(prev_text, prev_cfg.get("config_version", 0))
    util.atomic_write(CONFIG_PATH, new_text)
    return {"changed": True, "config_version": new_cfg["config_version"],
            "generation": generation, "tracks": rows}, new_cfg


def cmd_override(con, cfg, args):
    op = args.get("op")
    ticker = args.get("ticker")
    if op not in OVERRIDE_OPS:
        raise AppError("VALIDATION", f"op must be one of {sorted(OVERRIDE_OPS)}")
    if not ticker:
        raise AppError("VALIDATION", "override requires ticker")
    track = args.get("track")
    note = args.get("note")
    now = utc_now()
    if op == "unpin":
        # tombstone the matching pin override(s) for this ticker
        con.execute("UPDATE overrides SET tombstoned_at=? WHERE ticker=? AND op='pin' "
                    "AND tombstoned_at IS NULL", (now, ticker))
        # also record the unpin act for audit
        con.execute("INSERT INTO overrides (ticker, op, track, note, created_at) VALUES (?,?,?,?,?)",
                    (ticker, op, track, note, now))
    else:
        con.execute("INSERT INTO overrides (ticker, op, track, note, created_at) VALUES (?,?,?,?,?)",
                    (ticker, op, track, note, now))
    generation, rows = rc.recompute(con, cfg)
    ov = con.execute("SELECT id, ticker, op, track, note, created_at, tombstoned_at FROM overrides "
                     "WHERE ticker=? ORDER BY id DESC LIMIT 1", (ticker,)).fetchone()
    return {"override": dict(zip(
        ("id", "ticker", "op", "track", "note", "created_at", "tombstoned_at"), ov)),
        "generation": generation, "tracks": rows}


def _position_cols(args):
    req = ("symbol", "quantity")
    for k in req:
        if not args.get(k):
            raise AppError("VALIDATION", f"position requires {k}")
    now = utc_now()
    account = args.get("account") or ""
    return dict(symbol=args["symbol"], quantity=str(args["quantity"]),
                cost_basis=args.get("cost_basis"), currency=args.get("currency", "USD"),
                account=account, provenance=args.get("provenance", "manual"),
                opened_at=args.get("opened_at"), updated_at=now)


def _upsert_position(con, cols):
    # Older rows may have NULL account values. SQLite UNIQUE constraints treat
    # NULL as distinct, so normalize before upserting through the canonical key.
    con.execute("UPDATE positions SET account='' WHERE account IS NULL")
    con.execute(
        "INSERT INTO positions (symbol, quantity, cost_basis, currency, account, provenance, "
        "opened_at, updated_at) VALUES (?,?,?,?,?,?,?,?) "
        "ON CONFLICT(symbol, account, provenance) DO UPDATE SET "
        "quantity=excluded.quantity, cost_basis=excluded.cost_basis, currency=excluded.currency, "
        "opened_at=excluded.opened_at, updated_at=excluded.updated_at",
        (cols["symbol"], cols["quantity"], cols["cost_basis"], cols["currency"],
         cols["account"], cols["provenance"], cols["opened_at"], cols["updated_at"]))
    return _position_by_key(con, cols)


_POSITION_COLS = ("id", "symbol", "quantity", "cost_basis", "currency", "account",
                  "provenance", "opened_at", "updated_at")
_POSITION_SELECT = "SELECT " + ", ".join(_POSITION_COLS) + " FROM positions"


def _position_row(row, missing):
    if row is None:
        raise AppError("INTERNAL", missing)
    return {"position": dict(zip(_POSITION_COLS, row))}


def _position_by_key(con, cols):
    row = con.execute(
        _POSITION_SELECT + " WHERE symbol=? AND IFNULL(account,'')=IFNULL(?,'') AND provenance=?",
        (cols["symbol"], cols["account"], cols["provenance"])).fetchone()
    return _position_row(row, "position write succeeded but row could not be read back")


def _position_by_id(con, pid):
    row = con.execute(_POSITION_SELECT + " WHERE id=?", (pid,)).fetchone()
    return _position_row(row, "position replace succeeded but row could not be read back")


def cmd_position_set(con, cfg, args):
    return _upsert_position(con, _position_cols(args))


def cmd_position_replace(con, cfg, args):
    pid = args.get("id")
    if pid is None:
        raise AppError("VALIDATION", "position-replace requires id")
    cols = _position_cols(args)
    con.execute("UPDATE positions SET account='' WHERE account IS NULL")
    cur = con.execute(
        "UPDATE positions SET symbol=?, quantity=?, cost_basis=?, currency=?, account=?, "
        "provenance=?, opened_at=?, updated_at=? WHERE id=?",
        (cols["symbol"], cols["quantity"], cols["cost_basis"], cols["currency"],
         cols["account"], cols["provenance"], cols["opened_at"], cols["updated_at"], pid))
    if cur.rowcount == 0:
        raise AppError("NOT_FOUND", f"position {pid} not found")
    return _position_by_id(con, pid)


def cmd_position_delete(con, cfg, args):
    pid = args.get("id")
    if pid is None:
        raise AppError("VALIDATION", "position-delete requires id")
    cur = con.execute("DELETE FROM positions WHERE id=?", (pid,))
    if cur.rowcount == 0:
        raise AppError("NOT_FOUND", f"position {pid} not found")
    return {"position": {"id": pid, "deleted": True}}


def cmd_watchlist_set(con, cfg, args):
    if not args.get("name") or not args.get("kind"):
        raise AppError("VALIDATION", "watchlist-set requires name and kind")
    if args["kind"] not in ("candidate", "holding"):
        raise AppError("VALIDATION", "kind must be candidate|holding")
    tickers = args.get("tickers", [])
    if not isinstance(tickers, list):
        raise AppError("VALIDATION", "tickers must be a list")
    now = utc_now()
    prov = args.get("provenance", "manual")
    con.execute(
        "INSERT INTO watchlists (name, kind, tickers, provenance, scraped_at, stale, updated_at) "
        "VALUES (?,?,?,?,?,?,?) ON CONFLICT(name, provenance) DO UPDATE SET "
        "kind=excluded.kind, tickers=excluded.tickers, scraped_at=excluded.scraped_at, "
        "stale=excluded.stale, updated_at=excluded.updated_at",
        (args["name"], args["kind"], json.dumps(tickers), prov,
         args.get("scraped_at"), 1 if args.get("stale") else 0, now))
    row = con.execute(
        "SELECT id, name, kind, tickers, provenance, scraped_at, stale, updated_at "
        "FROM watchlists WHERE name=? AND provenance=?", (args["name"], prov)).fetchone()
    d = dict(zip(("id", "name", "kind", "tickers", "provenance", "scraped_at", "stale",
                  "updated_at"), row))
    d["tickers"] = json.loads(d["tickers"] or "[]")
    return {"watchlist": d}


def cmd_watchlist_delete(con, cfg, args):
    wid = args.get("id")
    if wid is None:
        raise AppError("VALIDATION", "watchlist-delete requires id")
    cur = con.execute("DELETE FROM watchlists WHERE id=?", (wid,))
    if cur.rowcount == 0:
        raise AppError("NOT_FOUND", f"watchlist {wid} not found")
    return {"watchlist": {"id": wid, "deleted": True}}


def cmd_denylist(con, cfg, args, add):
    ticker = (args.get("ticker") or "").strip().upper()
    if not ticker:
        raise AppError("VALIDATION", "denylist op requires ticker")
    dl = list(cfg.get("ticker_denylist", []))
    if add:
        if ticker not in dl:
            dl.append(ticker)
    else:
        dl = [t for t in dl if t != ticker]
    # denylist lives in config -> route through staged set-config (recompute+promote+archive)
    data, new_cfg = cmd_set_config(con, cfg, {"path": "ticker_denylist", "value": sorted(dl)})
    data["ticker"] = ticker
    return data, new_cfg


def cmd_alias(con, cfg, args, set_):
    if set_:
        alias, canonical = args.get("alias"), args.get("canonical")
        if not alias or not canonical:
            raise AppError("VALIDATION", "alias-set requires alias and canonical")
        aliases = dict(cfg.get("ticker_aliases", {}))
        aliases[alias.upper()] = canonical.upper()
    else:
        alias = args.get("alias")
        if not alias:
            raise AppError("VALIDATION", "alias-delete requires alias")
        aliases = dict(cfg.get("ticker_aliases", {}))
        aliases.pop(alias.upper(), None)
    data, new_cfg = cmd_set_config(con, cfg, {"path": "ticker_aliases", "value": aliases})
    return data, new_cfg


# ---------------- reads (lock-free) ----------------

def _last_run_id(con):
    r = con.execute("SELECT run_id FROM runs WHERE kind='debrief' AND committed_at IS NOT NULL "
                    "ORDER BY committed_at DESC LIMIT 1").fetchone()
    return r[0] if r else None


def cmd_get_state(con, cfg, args):
    regime = con.execute(
        "SELECT session_date, vix, vix_trend5d, fear_greed, put_call, oi_note, score, confidence "
        "FROM regime ORDER BY session_date DESC LIMIT 1").fetchone()
    regime_d = dict(zip(("session_date", "vix", "vix_trend5d", "fear_greed", "put_call",
                         "oi_note", "score", "confidence"), regime)) if regime else None
    tracks = [dict(zip(("ticker", "track", "status", "conviction", "entered_at",
                        "last_signal_at", "source", "config_version", "generation"), r))
              for r in con.execute(
        "SELECT ticker, track, status, conviction, entered_at, last_signal_at, source, "
        "config_version, generation FROM derived_state ORDER BY conviction DESC, ticker")]
    today = max((r[0] for r in con.execute("SELECT DISTINCT session_date FROM signals")),
                default=None)
    signals_today = []
    if today:
        signals_today = [dict(zip(("ticker", "direction", "strength", "best_rank", "origin_key",
                                   "track_proposal", "conviction", "thesis_type", "horizon",
                                   "justification"), r)) for r in con.execute(
            "SELECT ticker, direction, strength, best_rank, origin_key, track_proposal, "
            "capped_conviction, thesis_type, horizon, justification "
            "FROM signals WHERE session_date=? ORDER BY best_rank, ticker", (today,))]
    # diff: derived_state vs the scheduled tracks snapshot (model drift / override effect)
    canon = {r[0]: dict(zip(("track", "status", "conviction"), r[1:])) for r in con.execute(
        "SELECT ticker, track, status, conviction FROM tracks")}
    diff = []
    for t in tracks:
        c = canon.get(t["ticker"])
        if c is None or c["status"] != t["status"] or round(c["conviction"], 4) != round(
                t["conviction"], 4) or c["track"] != t["track"]:
            diff.append({"ticker": t["ticker"], "derived": {
                "track": t["track"], "status": t["status"], "conviction": t["conviction"],
                "source": t["source"]}, "scheduled": c})
    return {"regime": regime_d, "tracks": tracks, "signals_today": signals_today,
            "diff": diff, "health": _health(con, cfg), "generation": _generation(con),
            "config": cfg}


def cmd_get_ticker(con, cfg, args):
    ticker = args.get("ticker")
    if not ticker:
        raise AppError("VALIDATION", "get-ticker requires ticker")
    events = []
    sig_rows = con.execute(
        "SELECT event_ids FROM signals WHERE ticker=?", (ticker,)).fetchall()
    eids = set()
    for (ej,) in sig_rows:
        eids.update(json.loads(ej or "[]"))
    if eids:
        q = ",".join("?" * len(eids))
        events = [dict(zip(("event_id", "ts", "source", "author", "type", "text"), r))
                  for r in con.execute(
            f"SELECT event_id, ts, source, author, type, substr(text,1,400) FROM events "
            f"WHERE event_id IN ({q}) ORDER BY ts DESC", tuple(eids))]
    signals = [dict(zip(("signal_id", "session_date", "direction", "strength", "best_rank",
                         "origin_key", "track_proposal", "conviction", "model_conviction",
                         "thesis_type", "horizon", "justification", "speakers"), r))
               for r in con.execute(
        "SELECT signal_id, session_date, direction, strength, best_rank, origin_key, "
        "track_proposal, capped_conviction, model_conviction, thesis_type, horizon, "
        "justification, speakers FROM signals WHERE ticker=? ORDER BY session_date DESC",
        (ticker,))]
    conviction_history = [dict(zip(("run_id", "session_date", "track", "conviction"), r))
                          for r in con.execute(
        "SELECT run_id, session_date, track, conviction FROM conviction_history "
        "WHERE ticker=? ORDER BY session_date", (ticker,))]
    transitions = [dict(zip(("run_id", "session_date", "transition", "detail"), r))
                   for r in con.execute(
        "SELECT run_id, session_date, transition, detail FROM transitions "
        "WHERE ticker=? ORDER BY id", (ticker,))]
    ov = con.execute(
        "SELECT id, op, track, note, created_at FROM overrides WHERE ticker=? "
        "AND tombstoned_at IS NULL ORDER BY id DESC LIMIT 1", (ticker,)).fetchone()
    override = dict(zip(("id", "op", "track", "note", "created_at"), ov)) if ov else None
    return {"events": events, "signals": signals,
            "conviction_history": conviction_history, "transitions": transitions,
            "override": override}


def _health(con, cfg):
    adapters = []
    for src, sc in cfg["sources"].items():
        row = con.execute("SELECT MAX(ingested_at) FROM events WHERE source=?", (src,)).fetchone()
        adapters.append({"source": src, "enabled": bool(sc.get("enabled")),
                         "last_ingested_at": row[0] if row else None})
    last_runs = [dict(zip(("run_id", "kind", "started_at", "committed_at"), r))
                 for r in con.execute(
        "SELECT run_id, kind, started_at, committed_at FROM runs ORDER BY started_at DESC LIMIT 5")]
    return {"adapters": adapters, "last_runs": last_runs,
            "lock": _lock_held(), "schema_version": int(store.get_meta(con, "schema_version", "0"))}


def cmd_health(con, cfg, args):
    return _health(con, cfg)


def _generation(con):
    return int(store.get_meta(con, "generation", "0"))


# ---------------- notification outbox (app is the deliverer, 2026-07-01) ----------------

NOTIFY_LEASE_SECONDS = 120


def cmd_notify_claim(con, cfg, args):
    """Claim pending outbox rows (plus expired delivering leases) for the app to post as
    native notifications. pending -> delivering with a lease; the app acks after posting.
    A crash between claim and ack self-heals via lease expiry."""
    limit = int(args.get("limit", 50))
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat(timespec="seconds")
    lease = (now + timedelta(seconds=NOTIFY_LEASE_SECONDS)).isoformat(timespec="seconds")
    candidates = [r[0] for r in con.execute(
        "SELECT id FROM notifications WHERE state='pending' "
        "OR (state='delivering' AND (lease_until IS NULL OR lease_until < ?)) "
        "ORDER BY created_at LIMIT ?", (now_iso, limit))]
    claimed = []
    for nid in candidates:
        cur = con.execute(
            "UPDATE notifications SET state='delivering', lease_until=? "
            "WHERE id=? AND (state='pending' OR (state='delivering' AND "
            "(lease_until IS NULL OR lease_until < ?)))", (lease, nid, now_iso))
        if cur.rowcount:
            claimed.append(nid)
    rows = []
    if claimed:
        q = ",".join("?" * len(claimed))
        rows = [dict(zip(("id", "kind", "ticker", "run_id", "body", "created_at"), r))
                for r in con.execute(
            f"SELECT id, kind, ticker, run_id, body, created_at FROM notifications "
            f"WHERE id IN ({q}) ORDER BY created_at", claimed)]
    return {"notifications": rows, "lease_seconds": NOTIFY_LEASE_SECONDS}


def cmd_notify_ack(con, cfg, args):
    ids = args.get("ids")
    if not isinstance(ids, list) or not ids or not all(isinstance(i, str) for i in ids):
        raise AppError("VALIDATION", "notify-ack requires ids: [string, ...]")
    acked = 0
    for nid in ids:
        cur = con.execute(
            "UPDATE notifications SET state='delivered', delivered_at=?, lease_until=NULL "
            "WHERE id=? AND state='delivering'", (utc_now(), nid))
        acked += cur.rowcount
    return {"acked": acked}


# ---------------- dispatch ----------------

NO_RECOMPUTE_MUTATORS = {
    "position-set": cmd_position_set, "position-replace": cmd_position_replace,
    "position-delete": cmd_position_delete,
    "watchlist-set": cmd_watchlist_set, "watchlist-delete": cmd_watchlist_delete,
}


def run(cmd, args, _test_fail_recompute=False):
    cfg = store.config()
    if cmd in READ_CMDS:
        con = store.connect()
        con.execute("PRAGMA query_only=ON")
        try:
            if cmd == "get-state":
                data = cmd_get_state(con, cfg, args)
            elif cmd == "get-ticker":
                data = cmd_get_ticker(con, cfg, args)
            else:
                data = cmd_health(con, cfg, args)
            return _ok(con, cfg, data)
        finally:
            con.close()

    # mutating: lock -> tx -> bump generation -> commit
    with AppLock(cmd):
        con = store.connect()
        try:
            new_cfg = None
            with con:  # single transaction; rolls back on any exception
                if cmd == "recompute":
                    data = cmd_recompute(con, cfg, args)
                elif cmd == "set-config":
                    data, new_cfg = cmd_set_config(con, cfg, args,
                                                   fail_recompute=_test_fail_recompute)
                elif cmd == "override":
                    data = cmd_override(con, cfg, args)
                elif cmd == "denylist-add":
                    data, new_cfg = cmd_denylist(con, cfg, args, add=True)
                elif cmd == "denylist-remove":
                    data, new_cfg = cmd_denylist(con, cfg, args, add=False)
                elif cmd == "alias-set":
                    data, new_cfg = cmd_alias(con, cfg, args, set_=True)
                elif cmd == "alias-delete":
                    data, new_cfg = cmd_alias(con, cfg, args, set_=False)
                elif cmd == "notify-claim":
                    data = cmd_notify_claim(con, cfg, args)  # no generation bump: outbox
                elif cmd == "notify-ack":
                    data = cmd_notify_ack(con, cfg, args)    # state is not UI-staleness input
                elif cmd in NO_RECOMPUTE_MUTATORS:
                    data = NO_RECOMPUTE_MUTATORS[cmd](con, cfg, args)
                    store.bump_generation(con)
                else:
                    raise AppError("VALIDATION", f"unknown command {cmd!r}")
            effective_cfg = new_cfg or cfg
            return _ok(con, effective_cfg, data)
        finally:
            con.close()


def _ok(con, cfg, data):
    return {"status": "ok", "code": "OK", "generation": _generation(con),
            "config_version": int(cfg.get("config_version", 0)),
            "run_id": _last_run_id(con), "data": data}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"status": "error", "code": "VALIDATION",
                          "message": "usage: appctl.py <cmd> --json '<args>'"}))
        sys.exit(2)
    cmd = sys.argv[1]
    args = {}
    if "--json" in sys.argv:
        i = sys.argv.index("--json")
        try:
            args = json.loads(sys.argv[i + 1]) if i + 1 < len(sys.argv) else {}
        except (IndexError, json.JSONDecodeError) as e:
            print(json.dumps({"status": "error", "code": "VALIDATION",
                              "message": f"bad --json: {e}"}))
            sys.exit(2)
    if not isinstance(args, dict):
        print(json.dumps({"status": "error", "code": "VALIDATION",
                          "message": "args must be a JSON object"}))
        sys.exit(2)
    try:
        out = run(cmd, args)
        print(json.dumps(out))
    except AppError as e:
        cfg = store.config()
        print(json.dumps({"status": "error", "code": e.code, "message": e.message,
                          "config_version": int(cfg.get("config_version", 0))}))
        sys.exit(1)
    except Exception as e:  # noqa: BLE001 - protocol guarantees one JSON object out
        print(json.dumps({"status": "error", "code": "INTERNAL", "message": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
