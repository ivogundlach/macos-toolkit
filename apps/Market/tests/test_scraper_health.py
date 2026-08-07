"""Focused checks for Market website-scraper health contracts. No network or live DB."""
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "adapters"))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))

import market_regime as regime
import youtube_ytdlp as youtube


class FakeConnection:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def execute(self, *_args):
        return FakeCursor()


class FakeCursor:
    def fetchone(self):
        return None


def patch(module, **replacements):
    original = {name: getattr(module, name) for name in replacements}
    for name, value in replacements.items():
        setattr(module, name, value)
    return original


def restore(module, original):
    for name, value in original.items():
        setattr(module, name, value)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def test_regime_health(tmp):
    status = os.path.join(tmp, "regime.json")
    base = patch(
        regime,
        STATUS_PATH=status,
        get_vix=lambda: (20.0, 1.0),
        get_fear_greed=lambda: 50.0,
        get_options_stats=lambda: {"pc_vol": 1.0, "pc_oi": 1.1, "total_oi": 10, "source": "test"},
    )
    store_original = patch(
        regime.store,
        config=lambda: {"regime": {"weights": {"vix": 1, "fear_greed": 1, "put_call": 1}, "formula_version": 1}},
        connect=lambda: FakeConnection(),
        session_date=lambda _value: "2026-07-17",
        insert_event=lambda *_args, **_kwargs: 1,
        export_jsonl=lambda *_args, **_kwargs: None,
    )
    util_original = patch(regime.util, log=lambda *_args, **_kwargs: None)
    try:
        assert regime.main() == 0
        assert read(status)["status"] == "ok"
        regime.get_fear_greed = lambda: (_ for _ in ()).throw(RuntimeError("CNN unavailable"))
        assert regime.main() == 0
        payload = read(status)
        assert payload["status"] == "partial" and payload["errors"]
        regime.get_fear_greed = lambda: 50.0
        regime.get_vix = lambda: (_ for _ in ()).throw(RuntimeError("Yahoo unavailable"))
        assert regime.main() == 0
        payload = read(status)
        assert payload["status"] == "partial" and "vix" not in payload["available_components"]
        regime.get_vix = lambda: (_ for _ in ()).throw(RuntimeError("Yahoo unavailable"))
        regime.get_fear_greed = lambda: (_ for _ in ()).throw(RuntimeError("CNN unavailable"))
        regime.get_options_stats = lambda: (_ for _ in ()).throw(RuntimeError("options unavailable"))
        assert regime.main() == 1
        assert read(status)["status"] == "stale"
    finally:
        restore(regime.util, util_original)
        restore(regime.store, store_original)
        restore(regime, base)


def test_youtube_health(tmp):
    status = os.path.join(tmp, "youtube.json")
    config = {
        "sources": {"youtube": {"enabled": True, "channels": ["one", "two"], "rank": 4, "max_videos_per_channel": 8}},
        "limits": {"max_transcript_chars": 1000},
    }
    base = patch(youtube, STATUS_PATH=status, TMP=tmp)
    store_original = patch(
        youtube.store,
        config=lambda: config,
        connect=lambda: FakeConnection(),
        event_id=lambda _source, native_id: native_id,
        insert_event=lambda *_args, **_kwargs: 1,
        session_date=lambda _value: "2026-07-17",
        export_jsonl=lambda *_args, **_kwargs: None,
    )
    util_original = patch(youtube.util, log=lambda *_args, **_kwargs: None)
    try:
        youtube.list_recent = lambda channel, _limit: [] if channel == "one" else (_ for _ in ()).throw(RuntimeError("list failed"))
        assert youtube.main() == 1
        payload = read(status)
        assert payload["status"] == "partial_failure"
        assert payload["channels_checked"] == 1 and payload["channels_expected"] == 2

        config["sources"]["youtube"]["channels"] = ["one"]
        youtube.list_recent = lambda _channel, _limit: [{"id": "video1", "title": "Video", "timestamp": "1"}]
        youtube.fetch_transcript = lambda _video: (_ for _ in ()).throw(RuntimeError("caption fetch failed"))
        assert youtube.main() == 1
        payload = read(status)
        assert payload["transcript_failures"][0]["video"] == "video1"
        assert payload["new_events"] == 0

        youtube.fetch_transcript = lambda _video: "transcript"
        youtube.video_meta_ts = lambda _video: (_ for _ in ()).throw(RuntimeError("metadata failed"))
        youtube.list_recent = lambda _channel, _limit: [{"id": "video1", "title": "Video", "timestamp": "NA"}]
        assert youtube.main() == 1
        payload = read(status)
        assert payload["metadata_failures"][0]["video"] == "video1"
        assert payload["new_events"] == 0

        youtube.fetch_transcript = lambda _video: ""
        youtube.list_recent = lambda _channel, _limit: [{"id": "video1", "title": "Video", "timestamp": "1"}]
        assert youtube.main() == 0
        payload = read(status)
        assert payload["status"] == "ok"
        assert payload["transcripts_unavailable"] == ["video1"]
        assert payload["new_events"] == 1
    finally:
        restore(youtube.util, util_original)
        restore(youtube.store, store_original)
        restore(youtube, base)


def option_chain(puts, calls, market_state="REGULAR"):
    """Synthetic Yahoo optionChain result. puts/calls are (volume, open_interest) tuples."""
    def contracts(rows):
        return [{"volume": v, "openInterest": oi} for v, oi in rows]
    return {
        "quote": {"marketState": market_state},
        "options": [{"expirationDate": 1784678400,
                     "puts": contracts(puts), "calls": contracts(calls)}],
    }


def test_option_chain_summary():
    # Healthy volume sides with open interest still zero pre-market (the 2026-07-22 false
    # Fail): the volume ratio is valid, so the reading is accepted and OI is simply omitted.
    stats = regime.summarize_option_chain(
        option_chain([(800000, 0), (12914, 0)], [(600000, 0), (72305, 0)], "PREPRE"))
    assert stats["pc_vol"] == round(812914 / 672305, 3)
    assert "pc_oi" not in stats and "total_oi" not in stats

    # A fully populated chain also reports the open-interest note fields.
    stats = regime.summarize_option_chain(option_chain([(900, 1000)], [(1000, 1000)], "REGULAR"))
    assert stats["pc_vol"] == 0.9 and stats["pc_oi"] == 1.0 and stats["total_oi"] == 2000

    # Both volume sides empty while open interest is intact during a non-trading state is
    # Yahoo's morning publication lag -> pending (carried elsewhere), never a hard failure.
    try:
        regime.summarize_option_chain(option_chain([(0, 500)], [(0, 500)], "PREPRE"))
        raise AssertionError("expected VolumeNotPublished")
    except regime.VolumeNotPublished:
        pass

    # An asymmetric chain (one volume side empty) yields a false pc_vol extreme, so it stays a
    # hard error regardless of session state -- the 2026-07-20 maximally-bullish trap.
    for bad in (option_chain([(0, 500)], [(1000, 500)], "PREPRE"),
                option_chain([(1000, 500)], [(0, 500)], "REGULAR")):
        try:
            regime.summarize_option_chain(bad)
            raise AssertionError("expected ValueError for asymmetric chain")
        except ValueError:
            pass

    # Empty volumes during regular hours are a genuine outage, not the pre-market lag.
    try:
        regime.summarize_option_chain(option_chain([(0, 500)], [(0, 500)], "REGULAR"))
        raise AssertionError("expected ValueError during REGULAR")
    except ValueError:
        pass


def main():
    with tempfile.TemporaryDirectory(prefix="market-scraper-health-") as tmp:
        test_option_chain_summary()
        test_regime_health(tmp)
        test_youtube_health(tmp)
    print("scraper health checks passed")


if __name__ == "__main__":
    main()
