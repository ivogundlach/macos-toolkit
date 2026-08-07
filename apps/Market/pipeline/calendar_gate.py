"""Fluid debrief-day gate. Exit 0 = run the debrief today, exit 1 = skip.

Rule (mem_20260613_023723_17011): fire iff TOMORROW is the first or last trading day of
its Mon-Sun week on the NYSE (XNYS) calendar. Normal week -> Sunday and Thursday fire;
Monday holiday -> Monday fires (preps Tuesday); Friday holiday -> Wednesday fires.
Run with the project venv python (needs exchange_calendars).

A `delivery.go_live_not_before` date in config.json (optional) suppresses firing before
go-live; it gates BOTH run.py and the watchdog (no false MISSED alerts). `run.py debrief
--force` bypasses this gate entirely for manual dry runs.

Also exposes next_session(date) for labeling which session a debrief preps.
"""
import json
import os
import sys
from datetime import date, timedelta

import exchange_calendars as xcals

CAL = xcals.get_calendar("XNYS")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def go_live_not_before():
    """Optional config date before which the debrief never fires. None = no gate."""
    try:
        with open(os.path.join(ROOT, "config.json"), encoding="utf-8") as f:
            d = json.load(f).get("delivery", {}).get("go_live_not_before")
        return date.fromisoformat(d) if d else None
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def week_sessions(d: date):
    """NYSE sessions in d's Mon-Sun week."""
    monday = d - timedelta(days=d.weekday())
    sunday = monday + timedelta(days=6)
    sessions = CAL.sessions_in_range(monday.isoformat(), sunday.isoformat())
    return [s.date() for s in sessions]


def is_debrief_day(today: date) -> tuple[bool, str]:
    not_before = go_live_not_before()
    if not_before and today < not_before:
        return False, f"before go-live date {not_before}"
    tomorrow = today + timedelta(days=1)
    sessions = week_sessions(tomorrow)
    if not sessions:
        return False, f"no NYSE sessions in week of {tomorrow}"
    if tomorrow not in sessions:
        return False, f"tomorrow {tomorrow} is not a trading day"
    if tomorrow == sessions[0]:
        return True, f"tomorrow {tomorrow} is the FIRST trading day of its week"
    if tomorrow == sessions[-1]:
        return True, f"tomorrow {tomorrow} is the LAST trading day of its week"
    return False, f"tomorrow {tomorrow} is a mid-week trading day"


def next_session(today: date) -> date:
    """Next NYSE session strictly after `today` (today need not be a session)."""
    from datetime import timedelta
    nxt = CAL.date_to_session((today + timedelta(days=1)).isoformat(), direction="next")
    return nxt.date()


if __name__ == "__main__":
    today = date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else date.today()
    fire, reason = is_debrief_day(today)
    print(f"{today}: {'FIRE' if fire else 'skip'} - {reason}")
    sys.exit(0 if fire else 1)
