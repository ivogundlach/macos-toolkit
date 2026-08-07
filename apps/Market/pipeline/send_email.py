"""RETIRED 2026-07-01: email delivery removed (Ivo) — the app is the sole notification + debrief surface. Kept only as reference; no pipeline caller remains.

Full-debrief email via gws. At-most-once per run: a deterministic Message-ID is recorded
in the run ledger BEFORE sending; if a run already has a recorded send, we reconcile against
Gmail (search the Message-ID) instead of re-sending.
"""
import base64
import json
import os
import subprocess
import sys
from email.message import EmailMessage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store
import util

GWS = next((p for p in ("/opt/homebrew/bin/gws", "/usr/local/bin/gws") if os.path.exists(p)), "gws")


def message_id(run_id):
    return f"<market-debrief-{run_id}@market.local>"


def already_sent(run_id):
    """Reconcile: was this run's Message-ID already delivered?"""
    mid = message_id(run_id)
    q = json.dumps({"userId": "me", "q": f'rfc822msgid:{mid}'})
    out = subprocess.run([GWS, "gmail", "users", "messages", "list", "--params", q],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return False
    try:
        return bool(json.loads(out.stdout or "{}").get("messages"))
    except json.JSONDecodeError:
        return False


def build_mime(to, subject, html_body, run_id):
    """RFC-compliant message; EmailMessage handles header encoding (no mojibake)."""
    msg = EmailMessage()
    msg["To"] = to
    msg["Subject"] = subject
    msg["Message-ID"] = message_id(run_id)
    msg.set_content("This debrief is HTML. View in an HTML-capable client.")
    msg.add_alternative(html_body, subtype="html")
    return base64.urlsafe_b64encode(msg.as_bytes()).decode()


def send(con, cfg, run_id, subject, html_body):
    to = cfg["delivery"]["email_to"]
    # record intent in ledger first
    with con:
        con.execute("UPDATE runs SET manifest=json_set(COALESCE(manifest,'{}'),'$.email_msgid',?) WHERE run_id=?",
                    (message_id(run_id), run_id))
    if already_sent(run_id):
        util.log("send_email", f"run {run_id} already delivered (reconciled); skipping resend")
        return "reconciled"
    raw = build_mime(to, subject, html_body, run_id)
    out = subprocess.run([GWS, "gmail", "users", "messages", "send", "--params",
                          '{"userId":"me"}', "--json", json.dumps({"raw": raw})],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(f"gws send rc={out.returncode}: {out.stderr[:300]}")
    sent_id = json.loads(out.stdout or "{}").get("id", "?")
    with con:
        con.execute("UPDATE runs SET manifest=json_set(manifest,'$.email_sent_id',?) WHERE run_id=?",
                    (sent_id, run_id))
    util.log("send_email", f"run {run_id} delivered to {to} (gmail id {sent_id})")
    return sent_id
