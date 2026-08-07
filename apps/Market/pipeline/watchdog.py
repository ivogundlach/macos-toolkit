"""Independent watchdog (17:10 local). If today was a debrief day but no committed debrief
run exists for it, return failure for Tool Status Dashboard to repair/escalate.
"""
import os
import sys
from datetime import date, datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store
import util
import calendar_gate


def main():
    today = date.today()
    fire, _ = calendar_gate.is_debrief_day(today)
    if not fire:
        return
    con = store.connect()
    row = con.execute(
        "SELECT run_id FROM runs WHERE kind='debrief' AND committed_at IS NOT NULL "
        "AND date(started_at) = ?", (today.isoformat(),)).fetchone()
    if row:
        util.log("watchdog", f"ok: committed debrief {row[0]} exists for {today}")
        return
    msg = f"No committed debrief for {today} (a debrief day). Check out/launchd_logs/debrief.err."
    util.log("watchdog", f"ALERT: {msg}")
    raise SystemExit(1)


if __name__ == "__main__":
    main()
