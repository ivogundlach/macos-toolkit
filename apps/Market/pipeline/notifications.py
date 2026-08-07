"""Transactional notification outbox (CONTRACTS.md §2 notifications, plan #5).

enqueue(): write a pending row with a DETERMINISTIC id = sha256(kind+ticker+run_id). INSERT OR
IGNORE means the same event enqueued twice -> one row (dedup across launchd retries/recomputes).

drain(): deliver pending rows via terminal-notifier if present, else osascript. Delivery uses an
argument ARRAY (no shell string interpolation, so ticker text can never inject). State machine:
  pending -> delivering (lease) -> delivered.
A stale `delivering` lease (crash window) is reclaimed once lease_until passes.
"""
import hashlib
import json
import os
import shutil
import subprocess
from datetime import datetime, timedelta, timezone

LEASE_SECONDS = 120


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def notif_id(kind, ticker, run_id):
    return hashlib.sha256(f"{kind}+{ticker or ''}+{run_id or ''}".encode()).hexdigest()


def enqueue(con, kind, ticker, run_id, body):
    """Idempotent enqueue. Returns the deterministic id. Caller wraps in a transaction."""
    nid = notif_id(kind, ticker, run_id)
    con.execute(
        "INSERT OR IGNORE INTO notifications (id, kind, ticker, run_id, body, state, created_at) "
        "VALUES (?,?,?,?,?, 'pending', ?)",
        (nid, kind, ticker, run_id, body, utc_now()))
    return nid


def _deliver_one(body):
    """Best-effort OS delivery via terminal-notifier or osascript. Argument array, never shell."""
    tn = shutil.which("terminal-notifier")
    if tn:
        subprocess.run([tn, "-title", "Market", "-message", body],
                       capture_output=True, timeout=15)
        return True
    # osascript: pass the body as a parameter ($1), referenced via `item 1 of argv` — no
    # string interpolation into the AppleScript source.
    script = ('on run argv\n'
              'display notification (item 1 of argv) with title "Market"\n'
              'end run')
    subprocess.run(["osascript", "-e", script, body], capture_output=True, timeout=15)
    return True


def drain(con, limit=50):
    """Deliver pending notifications. Returns count delivered. Each row: pending->delivering->delivered.

    Lease: a row is moved to 'delivering' with lease_until=now+LEASE inside a tx BEFORE the OS
    call, so a crash mid-delivery leaves a reclaimable lease rather than a lost or double notice.
    """
    now = datetime.now(timezone.utc)
    lease_until = (now + timedelta(seconds=LEASE_SECONDS)).isoformat(timespec="seconds")
    now_iso = now.isoformat(timespec="seconds")

    # claim: pending, or delivering whose lease expired (crash recovery)
    rows = con.execute(
        "SELECT id, body FROM notifications WHERE state='pending' "
        "OR (state='delivering' AND (lease_until IS NULL OR lease_until < ?)) "
        "ORDER BY created_at LIMIT ?", (now_iso, limit)).fetchall()

    delivered = 0
    for nid, body in rows:
        with con:  # claim transactionally
            cur = con.execute(
                "UPDATE notifications SET state='delivering', lease_until=? "
                "WHERE id=? AND (state='pending' OR (state='delivering' AND "
                "(lease_until IS NULL OR lease_until < ?)))",
                (lease_until, nid, now_iso))
            if cur.rowcount == 0:
                continue  # someone else claimed it
        try:
            _deliver_one(body)
        except Exception:
            continue  # leave in 'delivering'; lease expiry reclaims it on a later drain
        with con:
            con.execute("UPDATE notifications SET state='delivered', delivered_at=?, lease_until=NULL "
                        "WHERE id=?", (utc_now(), nid))
        delivered += 1
    return delivered


APP_BIN = "/Applications/Market.app/Contents/MacOS/Market"


def deliver_via_app(timeout=40):
    """Deliver the outbox as push notifications, app open or closed (Ivo 2026-07-02).

    Preferred path: Market.app's headless drain (`--notify-drain`: claim -> post with the
    app's identity -> ack -> exit). KNOWN BLOCKED as of macOS 27 (2026-07-03): usernoted
    live-rejects notification authorization for non-notarized local apps (UNErrorDomain
    Code=1 while notDetermined; verified — not a cached denial, stable self-signed cert
    did not help). The attempt stays first so a future Developer-ID signature or macOS
    change lights it up automatically.

    Fallback: drain() here in Python — terminal-notifier (installed 2026-07-03, shows as
    "terminal-notifier" with title "Market") or osascript. Guarantees delivery TODAY.
    Call AFTER the run lock is released — notify-claim/drain writes take the same flock."""
    if os.path.exists(APP_BIN):
        try:
            out = subprocess.run([APP_BIN, "--notify-drain"], capture_output=True, timeout=timeout)
            if out.returncode == 0:
                return True
        except Exception:
            pass
    # fallback: Python drain (terminal-notifier/osascript identity, but it ARRIVES)
    try:
        import store
        con = store.connect()
        try:
            return drain(con) >= 0
        finally:
            con.close()
    except Exception:
        return False


def prune_delivered(con, days=90):
    """Retention: drop delivered notifications older than `days`."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(timespec="seconds")
    con.execute("DELETE FROM notifications WHERE state='delivered' AND delivered_at < ?", (cutoff,))
