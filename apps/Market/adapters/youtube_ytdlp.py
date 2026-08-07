"""YouTube adapter: yt-dlp lists recent uploads per configured channel, pulls auto-captions
for unseen videos, stores one event per video with a condensed transcript.
"""
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pipeline"))
import store
import util

TMP = os.path.join(store.ROOT, "out", "raw", "youtube")
YTDLP = next((p for p in ("/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp") if os.path.exists(p)), "yt-dlp")
STATUS_FILENAME = (
    "youtube_scrape_status.json"
    if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1"
    else "youtube_scrape_status.interactive.json"
)
STATUS_PATH = os.path.join(store.ROOT, "state", STATUS_FILENAME)


def write_status(status, **fields):
    payload = {
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "execution_context": "background" if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1" else "interactive",
        "status": status,
        **fields,
    }
    temporary = STATUS_PATH + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, STATUS_PATH)


def list_recent(channel_id: str, limit: int):
    out = subprocess.run(
        [YTDLP, "--flat-playlist", "--playlist-end", str(limit),
         "--print", "%(id)s\t%(title)s\t%(timestamp)s",
         f"https://www.youtube.com/channel/{channel_id}/videos"],
        capture_output=True, text=True, timeout=120,
    )
    if out.returncode != 0:
        raise RuntimeError(f"yt-dlp list rc={out.returncode}: {out.stderr[:300]}")
    vids = []
    for line in out.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) >= 1 and parts[0]:
            vids.append({"id": parts[0],
                         "title": parts[1] if len(parts) > 1 else "",
                         "timestamp": parts[2] if len(parts) > 2 else "NA"})
    if not vids:
        raise RuntimeError("yt-dlp returned no videos for a configured channel")
    return vids


def fetch_transcript(video_id: str) -> str:
    os.makedirs(TMP, exist_ok=True)
    base = os.path.join(TMP, video_id)
    for stale in glob.glob(f"{base}*.json3"):
        os.remove(stale)
    out = subprocess.run(
        [YTDLP, "--skip-download", "--write-auto-subs", "--write-subs",
         "--sub-langs", "en.*", "--sub-format", "json3", "-o", base,
         f"https://www.youtube.com/watch?v={video_id}"],
        capture_output=True, text=True, timeout=180,
    )
    files = glob.glob(f"{base}*.json3")
    if not files:
        detail = (out.stderr or out.stdout or "").strip()
        unavailable = any(marker in detail.lower() for marker in (
            "no subtitles", "does not have subtitles", "subtitles are not available",
        ))
        if out.returncode != 0 and not unavailable:
            raise RuntimeError(f"yt-dlp transcript rc={out.returncode}: {detail[:300]}")
        return ""
    with open(files[0], encoding="utf-8") as f:
        data = json.load(f)
    words = []
    for ev in data.get("events", []):
        for seg in ev.get("segs", []) or []:
            t = seg.get("utf8", "")
            if t and t != "\n":
                words.append(t)
    text = re.sub(r"\s+", " ", "".join(words)).strip()
    return text


def video_meta_ts(video_id: str) -> str:
    out = subprocess.run(
        [YTDLP, "--skip-download", "--print", "%(timestamp)s",
         f"https://www.youtube.com/watch?v={video_id}"],
        capture_output=True, text=True, timeout=60,
    )
    if out.returncode != 0:
        raise RuntimeError(f"yt-dlp metadata rc={out.returncode}: {(out.stderr or '')[:300]}")
    raw = out.stdout.strip()
    if raw.isdigit():
        return datetime.fromtimestamp(int(raw), tz=timezone.utc).isoformat(timespec="seconds")
    raise RuntimeError(f"yt-dlp returned invalid timestamp {raw!r}")


def main():
    cfg = store.config()
    scfg = cfg["sources"]["youtube"]
    if not scfg.get("enabled"):
        write_status("disabled")
        return 0
    max_chars = cfg["limits"]["max_transcript_chars"]
    con = store.connect()
    new_total = 0
    days = set()
    channel_failures = []
    transcript_failures = []
    metadata_failures = []
    transcripts_unavailable = []
    channels_checked = []
    for channel in scfg["channels"]:
        try:
            vids = list_recent(channel, scfg.get("max_videos_per_channel", 8))
        except Exception as e:
            util.log("youtube_ytdlp", f"{channel} list FAILED: {e}")
            channel_failures.append({"channel": channel, "error": str(e)[:300]})
            continue
        channels_checked.append(channel)
        for v in vids:
            eid = store.event_id("youtube", v["id"])
            if con.execute("SELECT 1 FROM events WHERE event_id=?", (eid,)).fetchone():
                continue
            try:
                ts = (datetime.fromtimestamp(int(v["timestamp"]), tz=timezone.utc).isoformat(timespec="seconds")
                      if v["timestamp"].isdigit() else video_meta_ts(v["id"]))
            except Exception as e:
                util.log("youtube_ytdlp", f"{v['id']} metadata FAILED: {e}")
                metadata_failures.append({"video": v["id"], "error": str(e)[:300]})
                continue
            transcript = ""
            try:
                transcript = fetch_transcript(v["id"])
            except Exception as e:
                util.log("youtube_ytdlp", f"{v['id']} transcript FAILED: {e}")
                transcript_failures.append({"video": v["id"], "error": str(e)[:300]})
                continue
            if not transcript:
                transcripts_unavailable.append(v["id"])
            text = f"{v['title']}\n\n{transcript[:max_chars]}" if transcript else v["title"]
            with con:
                new_total += store.insert_event(
                    con, source="youtube", native_id=v["id"], ts=ts, rank=scfg["rank"],
                    author=channel, type_="video", text=text,
                    urls=[f"https://www.youtube.com/watch?v={v['id']}"],
                    engagement={}, raw_ref=os.path.join(TMP, v["id"]),
                )
                days.add(store.session_date(ts))
        util.log("youtube_ytdlp", f"{channel}: done")
    with con:
        for day in days:
            store.export_jsonl(con, "youtube", day)
    util.log("youtube_ytdlp", f"done: {new_total} new videos")
    failed = bool(channel_failures or metadata_failures or transcript_failures)
    write_status(
        "partial_failure" if failed else "ok",
        channels_checked=len(channels_checked),
        channels_expected=len(scfg["channels"]),
        channel_failures=channel_failures,
        metadata_failures=metadata_failures,
        transcript_failures=transcript_failures,
        transcripts_unavailable=transcripts_unavailable,
        new_events=new_total,
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main() or 0)
