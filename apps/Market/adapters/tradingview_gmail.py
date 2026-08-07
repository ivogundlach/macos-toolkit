"""TradingView alert adapter: reads plain-text alert emails under the tradingview-alerts
label via gws CLI, persists them as rank-2 events, then trashes the message.

Lifecycle (mem_20260613_023720): filter keeps alerts out of the inbox; trash happens ONLY
after the event row is durably committed; trash failure is safe (dedup absorbs re-reads).
"""
import base64
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pipeline"))
import store
import util

GWS = next((p for p in ("/opt/homebrew/bin/gws", "/usr/local/bin/gws") if os.path.exists(p)), "gws")
LABEL_NAME = "tradingview-alerts"
CASHTAG_RE = re.compile(r"\$([A-Z]{1,5})\b")
EXCHSYM_RE = re.compile(r"\b(?:NYSE|NASDAQ|AMEX|CBOE|BATS):([A-Z]{1,5})\b")


def gws_json(args, timeout=60):
    out = subprocess.run([GWS, *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(f"gws {' '.join(args[:4])} rc={out.returncode}: {out.stderr[:300]}")
    # gws prints a keyring notice to stderr; stdout is pure JSON
    return json.loads(out.stdout) if out.stdout.strip() else {}


def label_id():
    data = gws_json(["gmail", "users", "labels", "list", "--params", '{"userId":"me"}'])
    for lab in data.get("labels", []):
        if lab["name"] == LABEL_NAME:
            return lab["id"]
    raise RuntimeError(f"label {LABEL_NAME!r} not found; create it + the filter first")


def list_message_ids(lid):
    params = json.dumps({"userId": "me", "labelIds": [lid], "maxResults": 100})
    data = gws_json(["gmail", "users", "messages", "list", "--params", params])
    return [m["id"] for m in data.get("messages", [])]


def body_text(payload) -> str:
    if payload.get("mimeType", "").startswith("text/") and payload.get("body", {}).get("data"):
        return base64.urlsafe_b64decode(payload["body"]["data"] + "==").decode("utf-8", "replace")
    parts = payload.get("parts", []) or []
    plain = [p for p in parts if p.get("mimeType") == "text/plain"]
    for p in plain + parts:
        text = body_text(p)
        if text:
            return text
    return ""


def fetch(msg_id):
    params = json.dumps({"userId": "me", "id": msg_id, "format": "full"})
    msg = gws_json(["gmail", "users", "messages", "get", "--params", params])
    headers = {h["name"].lower(): h["value"] for h in msg["payload"].get("headers", [])}
    subject = headers.get("subject", "")
    ts = datetime.fromtimestamp(int(msg["internalDate"]) / 1000, tz=timezone.utc)
    text = f"{subject}\n{body_text(msg['payload'])}".strip()
    return {"id": msg_id, "ts": ts.isoformat(timespec="seconds"), "subject": subject,
            "text": text, "from": headers.get("from", "")}


def trash(msg_id):
    params = json.dumps({"userId": "me", "id": msg_id})
    gws_json(["gmail", "users", "messages", "trash", "--params", params])


def main():
    cfg = store.config()
    scfg = cfg["sources"]["tradingview"]
    if not scfg.get("enabled"):
        util.log("tradingview_gmail", "disabled in config; nothing to do")
        return
    con = store.connect()
    lid = label_id()
    new = trashed = 0
    days = set()
    for msg_id in list_message_ids(lid):
        eid = store.event_id("tradingview", msg_id)
        already = con.execute("SELECT 1 FROM events WHERE event_id=?", (eid,)).fetchone()
        if not already:
            m = fetch(msg_id)
            tickers = set(CASHTAG_RE.findall(m["text"])) | set(EXCHSYM_RE.findall(m["text"]))
            with con:  # durable commit BEFORE trash
                new += store.insert_event(
                    con, source="tradingview", native_id=msg_id, ts=m["ts"],
                    rank=scfg["rank"], author=m["subject"][:120] or "tradingview-alert",
                    type_="alert", text=m["text"], tickers=tickers,
                    urls=[], engagement={}, raw_ref="",
                )
            days.add(store.session_date(m["ts"]))
        try:
            trash(msg_id)
            trashed += 1
        except Exception as e:
            util.log("tradingview_gmail", f"trash {msg_id} failed (safe, will retry): {e}")
    with con:
        for day in days:
            store.export_jsonl(con, "tradingview", day)
    util.log("tradingview_gmail", f"done: {new} new alerts, {trashed} trashed")


if __name__ == "__main__":
    main()
