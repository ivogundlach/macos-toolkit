#!/usr/bin/env python3
"""Fixture checks for Market scraper coverage in the Dashboard producer."""
import datetime as dt
import importlib.util
import json
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tool_status_scan", HERE / "tool-status-scan.py")
scanner = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(scanner)

# Keep deadline assertions independent of the wall-clock hour at which this
# regression test runs.
REAL_DATETIME = dt.datetime
FIXED_LOCAL_NOW = REAL_DATETIME.now().astimezone().replace(
    hour=12, minute=0, second=0, microsecond=0,
)


class FixedDateTime(REAL_DATETIME):
    @classmethod
    def now(cls, tz=None):
        return FIXED_LOCAL_NOW.astimezone(tz) if tz else FIXED_LOCAL_NOW.replace(tzinfo=None)


scanner.dt.datetime = FixedDateTime


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def row_for(home: Path, *, last_exit: str = "0", state: str = "not running") -> dict:
    scanner.HOME = home
    scanner.launchctl_job = lambda _label: {"last exit code": last_exit, "state": state}
    rows = []
    scanner.market_records(rows)
    assert len(rows) == 1
    return rows[0]


def setup(home: Path) -> tuple[Path, Path, Path]:
    for path in (
        home / "Library/LaunchAgents/com.ivo.market.refresh.plist",
        home / "Applications/Market.app/Contents/MacOS/Market",
        home / ".local/bin/market-refresh",
        home / "Projects/Market/scripts/market-refresh",
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture", encoding="utf-8")
    today = dt.datetime.now().astimezone().date().isoformat()
    stamps = home / "Projects/Market/out/background_stamps"
    stamps.mkdir(parents=True)
    for stage in ("ingest", "debrief", "watchdog"):
        (stamps / f"{stage}.{today}").touch()

    state = home / "Projects/Market/state"
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    x_path = state / "x_scrape_status.json"
    regime_path = state / "regime_scrape_status.json"
    youtube_path = state / "youtube_scrape_status.json"
    write_json(x_path, {
        "checked_at": now, "execution_context": "background", "status": "ok",
        "handles_checked": 4, "handles_expected": 4, "new_events": 1,
        "handle_results": {
            name: {"observed_posts": 1, "newest_observed": now}
            for name in ("one", "two", "three", "four")
        },
        "window_days": 30,
    })
    write_json(regime_path, {
        "checked_at": now, "execution_context": "background", "status": "ok", "errors": [],
    })
    write_json(youtube_path, {
        "checked_at": now, "execution_context": "background", "status": "ok",
        "channels_checked": 2, "channels_expected": 2, "channel_failures": [], "transcript_failures": [],
        "metadata_failures": [],
    })
    return x_path, regime_path, youtube_path


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="dashboard-market-health-") as tmp:
        home = Path(tmp)
        x_path, regime_path, youtube_path = setup(home)
        write_json(home / "Projects/Market/config.json", {
            "sources": {"tradingview": {"enabled": False}, "discord": {"enabled": False}},
        })
        assert row_for(home)["state"] == "ok"
        assert "registered scraper health" in row_for(home)["headline"]
        write_json(home / "Projects/Market/config.json", {
            "sources": {"tradingview": {"enabled": True}, "discord": {"enabled": False}},
        })
        assert row_for(home)["causeCode"] == "market.source_health_unregistered"
        write_json(home / "Projects/Market/config.json", {
            "sources": {"tradingview": {"enabled": False}, "discord": {"enabled": False}},
        })
        row = row_for(home, last_exit="15")
        assert row["state"] == "fail" and row["causeCode"] == "market.scheduler_last_run_failed"
        assert row["fix"]["command"] == [str(home / ".local/bin/market-refresh"), "--request-ingest"]
        running = row_for(home, last_exit="15", state="running")
        assert running["state"] == "warn" and "in progress" in running["headline"]

        ingest_stamp = home / "Projects/Market/out/background_stamps" / f"ingest.{dt.datetime.now().astimezone().date().isoformat()}"
        ingest_stamp.unlink()
        attempt = home / "Projects/Market/state/background/ingest.last_attempt"
        attempt.parent.mkdir(parents=True, exist_ok=True)
        attempt.write_text(dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), encoding="utf-8")
        assert row_for(home)["state"] == "ok", "active ingest must not be reported overdue"
        attempt.write_text(
            (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=41)).isoformat(timespec="seconds"),
            encoding="utf-8",
        )
        assert "ingest is overdue" in row_for(home)["detail"]
        attempt.write_text(
            (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=2)).isoformat(timespec="seconds"),
            encoding="utf-8",
        )
        assert "ingest is overdue" in row_for(home)["detail"], "future attempt must not suppress overdue"
        ingest_stamp.touch()

        x = json.loads(x_path.read_text())
        x["authentication_only"] = True
        write_json(x_path, x)
        row = row_for(home)
        assert row["state"] == "fail" and row["causeCode"] == "market.x_scrape_status_incomplete"
        x.pop("authentication_only")

        x["status"] = "auth_required"
        write_json(x_path, x)
        row = row_for(home)
        assert row["state"] == "fail" and row["causeCode"] == "market.x_auth_required"

        x["status"] = "ok"
        write_json(x_path, x)
        regime = json.loads(regime_path.read_text())
        regime.update({"status": "partial", "errors": ["fear_greed: unavailable"]})
        write_json(regime_path, regime)
        row = row_for(home)
        assert row["causeCode"] == "market.regime_scrape_degraded"
        assert row["fix"]["command"] == [str(home / ".local/bin/market-refresh"), "--request-ingest"]

        # put/call missing only because Yahoo had not published the chain's volume yet is not
        # a fault: ingest runs inside that window and no forced retry can shorten it.
        pending_reason = {
            "code": "options.volume_not_published",
            "detail": "SPY chain volume not published yet (marketState=PRE ...)",
        }
        regime.update({
            "status": "pending_session",
            "confidence": "partial",
            "errors": [],
            "pending": [pending_reason],
            "available_components": ["fear_greed", "vix"],
            "put_call_last_seen": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        })
        write_json(regime_path, regime)
        assert row_for(home)["state"] == "ok", "pre-session put/call gap must not fail the item"

        # The claim is verified, not trusted. Each of these is "pending_session" too, but none
        # satisfies the invariant, so the producer cannot mark itself healthy through it.
        for bad, why in (
            ({"errors": ["fear_greed: unavailable"]}, "a real error rode in alongside pending"),
            ({"pending": []}, "no pending reason was recorded"),
            ({"pending": "a bare string"}, "pending must be a list, not a scalar"),
            ({"pending": ["a bare string"]}, "a pending entry must be a structured reason"),
            ({"pending": [{"code": ""}]}, "an empty reason code is not waivable"),
            ({"pending": [{"code": "options.something_else"}]}, "an unknown code is not waivable"),
            ({"pending": [pending_reason, {"code": "other.reason"}]}, "a second reason rode in"),
            ({"errors": "a bare string"}, "errors must be a list, not a scalar"),
            ({"available_components": ["vix"]}, "a second component was missing too"),
            ({"available_components": ["fear_greed", "put_call", "vix"]}, "components disagree"),
            ({"available_components": "fear_greed,vix"}, "components must be a list"),
            ({"confidence": "full"}, "confidence must agree that the row is partial"),
        ):
            spoof = dict(regime, **bad)
            write_json(regime_path, spoof)
            row = row_for(home)
            assert row["state"] == "fail" and row["causeCode"] == "market.regime_scrape_degraded", why

        # The same gap once volume is published is still a real failure the scrapers repair.
        # A weekend-length gap in put/call must NOT page on its own: the waiver is not bounded
        # by wall clock, precisely so a long market closure cannot reintroduce a false alarm.
        regime.update({
            "pending": [pending_reason],
            "put_call_last_seen": (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=80)).isoformat(timespec="seconds"),
        })
        write_json(regime_path, regime)
        assert row_for(home)["state"] == "ok", "a long market closure must not page"

        regime.update({
            "status": "partial",
            "errors": ["options: empty SPY chain volumes (marketState=REGULAR ...)"],
            "pending": [],
            "available_components": ["fear_greed", "vix"],
        })
        write_json(regime_path, regime)
        row = row_for(home)
        assert row["state"] == "fail" and row["causeCode"] == "market.regime_scrape_degraded"
        assert row["fix"]["command"] == [str(home / ".local/bin/market-refresh"), "--request-ingest"]

        regime.pop("pending", None)
        regime.pop("put_call_last_seen", None)
        regime["available_components"] = ["fear_greed", "put_call", "vix"]
        regime.update({"status": "ok", "confidence": "full", "errors": []})
        write_json(regime_path, regime)
        youtube = json.loads(youtube_path.read_text())
        youtube.update({"status": "partial_failure", "channel_failures": [{"channel": "one"}]})
        write_json(youtube_path, youtube)
        row = row_for(home)
        assert row["causeCode"] == "market.youtube_scrape_degraded"

        youtube.update({"status": "ok", "channel_failures": []})
        write_json(youtube_path, youtube)
        x["checked_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=31)).isoformat(timespec="seconds")
        write_json(x_path, x)
        row = row_for(home)
        assert row["causeCode"] == "market.x_status_stale"

        x["checked_at"] = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=2)).isoformat(timespec="seconds")
        write_json(x_path, x)
        row = row_for(home)
        assert row["causeCode"] == "market.x_status_invalid"

        x["checked_at"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        x["handles_checked"] = 3
        write_json(x_path, x)
        row = row_for(home)
        assert row["causeCode"] == "market.x_profile_coverage_incomplete"

        x["handles_checked"] = 4
        x["handle_results"]["one"]["observed_posts"] = 0
        write_json(x_path, x)
        row = row_for(home)
        assert row["causeCode"] == "market.x_profile_render_empty"

        x["handle_results"]["one"]["observed_posts"] = 1
        x["handle_results"]["one"]["newest_observed"] = None
        write_json(x_path, x)
        row = row_for(home)
        assert row["causeCode"] == "market.x_profile_timestamp_missing"

        x["handle_results"]["one"]["newest_observed"] = (
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=31)
        ).isoformat(timespec="seconds")
        write_json(x_path, x)
        row = row_for(home)
        assert row["causeCode"] == "market.x_profile_stale"

        x["handle_results"]["one"]["newest_observed"] = (
            dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=2)
        ).isoformat(timespec="seconds")
        write_json(x_path, x)
        row = row_for(home)
        assert row["causeCode"] == "market.x_profile_stale"

    print("Market Dashboard scraper-health checks passed")


if __name__ == "__main__":
    main()
