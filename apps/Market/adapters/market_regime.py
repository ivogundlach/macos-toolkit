"""Market-regime adapter: VIX (Yahoo), Fear & Greed (CNN), put/call (CBOE).
Deterministic formula_version 1 score in [0,100]; 50 neutral, higher = bullish.
Missing inputs lower confidence instead of failing the run.
"""
import http.cookiejar
import json
import os
import statistics
import sys
import urllib.request
from datetime import date, datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pipeline"))
import store
import util

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36"
STATUS_FILENAME = (
    "regime_scrape_status.json"
    if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1"
    else "regime_scrape_status.interactive.json"
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


def read_status():
    """Previous health status, so a carried field survives across runs."""
    try:
        with open(STATUS_PATH, encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def fetch_json(url, timeout=25, headers=None, opener=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    op = opener.open if opener else urllib.request.urlopen
    with op(req, timeout=timeout) as r:
        return json.load(r)


def get_vix():
    data = fetch_json("https://query1.finance.yahoo.com/v8/finance/chart/%5EVIX?range=10d&interval=1d")
    closes = [c for c in data["chart"]["result"][0]["indicators"]["quote"][0]["close"] if c is not None]
    vix = closes[-1]
    trend5d = vix - statistics.mean(closes[-6:-1]) if len(closes) >= 6 else 0.0
    return round(vix, 2), round(trend5d, 2)


def get_fear_greed():
    data = fetch_json(
        "https://production.dataviz.cnn.io/index/fearandgreed/graphdata",
        headers={"Accept": "application/json",
                 "Referer": "https://edition.cnn.com/markets/fear-and-greed"},
    )
    return round(float(data["fear_and_greed"]["score"]), 1)


class VolumeNotPublished(Exception):
    """Yahoo has not published volume for the nearest expiry yet; open interest is intact."""


def get_options_stats():
    """SPY nearest-expiry put/call (volume) + OI from Yahoo; needs cookie+crumb."""
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    try:
        opener.open(urllib.request.Request("https://fc.yahoo.com", headers={"User-Agent": UA}), timeout=15)
    except urllib.error.HTTPError:
        pass  # fc.yahoo.com 404s by design; it only exists to set cookies
    with opener.open(urllib.request.Request(
            "https://query1.finance.yahoo.com/v1/test/getcrumb",
            headers={"User-Agent": UA}), timeout=15) as r:
        crumb = r.read().decode().strip()
    data = fetch_json(f"https://query1.finance.yahoo.com/v7/finance/options/SPY?crumb={crumb}",
                      opener=opener)
    return summarize_option_chain(data["optionChain"]["result"][0])


def summarize_option_chain(result):
    """Reduce a Yahoo optionChain result to put/call stats, or raise.

    Pure (no network) so the trap-laden validation below is unit-testable. The daily score
    consumes only the *volume* ratio pc_vol; open interest never enters it (substituting OI
    was measured to fabricate signal, 2026-07-20). So a healthy pair of volume sides is a
    trustworthy reading on its own, and open interest is surfaced as an optional note rather
    than gating that reading.
    """
    opts = result["options"][0]
    pv = sum(o.get("volume") or 0 for o in opts["puts"])
    cv = sum(o.get("volume") or 0 for o in opts["calls"])
    poi = sum(o.get("openInterest") or 0 for o in opts["puts"])
    coi = sum(o.get("openInterest") or 0 for o in opts["calls"])
    if not (pv and cv):
        state = str((result.get("quote") or {}).get("marketState") or "").upper()
        # Aggregation collapses null and 0 identically, so record the chain's shape here:
        # it makes the next occurrence diagnosable without a live reproduction.
        null_volume = sum(1 for o in opts["puts"] + opts["calls"] if o.get("volume") is None)
        detail = (f"marketState={state or 'unknown'} expiry={opts.get('expirationDate')} "
                  f"contracts={len(opts['puts'])}p/{len(opts['calls'])}c null_volume={null_volume} "
                  f"put_vol={pv} call_vol={cv} put_oi={poi} call_oi={coi}")
        # Observed 2026-07-20: Yahoo rolls the nearest expiry after the prior close but does
        # not backfill that chain's *volume* for several hours, so every contract reports null
        # volume overnight and well into pre-market. Background ingest fires at 08:00 local,
        # inside that window, which is what produced a daily failure. It is a publication lag,
        # not a scraper fault: it clears on its own and a forced retry cannot shorten it. Gate
        # on Yahoo's own marketState rather than a hardcoded exchange calendar, and treat any
        # unrecognised state as a fault so a schema change still fails loud. Require *both*
        # volume sides before trusting a ratio: a populated call side with an empty put side
        # yields pc_vol=0.0, which scores as maximally bullish, so an asymmetric chain is an
        # error rather than a lag.
        if not pv and not cv and poi and coi and state in {"PRE", "PREPRE", "CLOSED"}:
            raise VolumeNotPublished(f"SPY chain volume not published yet ({detail})")
        raise ValueError(f"empty SPY chain volumes ({detail})")
    stats = {"pc_vol": round(pv / cv, 3), "source": "yahoo-spy-nearest-expiry"}
    # Open interest backfills late pre-market too (observed 2026-07-22: both volume sides
    # healthy while both OI sides read 0 during PREPRE), exactly as volume does. It is
    # best-effort context, never a precondition for the volume reading the score consumes.
    if poi and coi:
        stats["pc_oi"] = round(poi / coi, 3)
        stats["total_oi"] = poi + coi
    return stats


def last_observed_put_call(con, day, max_age_days=4):
    """Most recent directly observed put/call, for carrying across a publication lag.

    Only a reading taken straight from a chain qualifies, so carries never chain off one
    another, and only a recent one, so a multi-day upstream outage degrades the score instead
    of freezing a stale number in place. Four days covers a Friday-to-Tuesday exchange close.
    """
    for row_day, value, raw in con.execute(
        "SELECT session_date, put_call, raw FROM regime "
        "WHERE put_call IS NOT NULL AND session_date <= ? ORDER BY session_date DESC LIMIT 8",
        (day,),
    ):
        try:
            observed = bool((json.loads(raw or "{}").get("options") or {}))
        except ValueError:
            observed = False
        if not observed:
            continue
        if (date.fromisoformat(day) - date.fromisoformat(row_day)).days <= max_age_days:
            return value, row_day
        break
    return None, None


def clamp(x, lo=0.0, hi=100.0):
    return max(lo, min(hi, x))


def score_components(vix, vix_trend, fg, pc):
    """Each component mapped to [0,100] bullishness."""
    comps = {}
    if vix is not None:
        base = clamp(100 - (vix - 10) * (100 / 30))          # VIX 10 -> 100, VIX 40+ -> 0
        base -= clamp(vix_trend, -10, 10) * 2                 # rising VIX = extra bearish
        comps["vix"] = clamp(base)
    if fg is not None:
        comps["fear_greed"] = clamp(fg)                       # already 0-100
    if pc is not None:
        comps["put_call"] = clamp(100 - (pc - 0.7) * (100 / 0.6))  # 0.7 -> 100, 1.3+ -> 0
    return comps


def main():
    cfg = store.config()
    rcfg = cfg["regime"]
    vix = trend = fg = pc = None
    oi = {}
    errors = []
    pending = []
    try:
        vix, trend = get_vix()
    except Exception as e:
        errors.append(f"vix: {e}")
    try:
        fg = get_fear_greed()
    except Exception as e:
        errors.append(f"fear_greed: {e}")
    try:
        oi = get_options_stats()
        pc = oi["pc_vol"]
    except VolumeNotPublished as e:
        pending.append({"code": "options.volume_not_published", "detail": str(e)})
    except Exception as e:
        errors.append(f"options: {e}")

    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    day = store.session_date(now)
    con = store.connect()

    # Yahoo serves the last completed session's chain on every non-trading day, and this score
    # has always accepted that at full confidence: 2026-07-18 and 07-19 both scored the same
    # 1.198 reading carried from Friday, as did 07-03/04/05 at 0.942. The morning publication
    # lag makes that identical fact disappear for a few hours while the rolled chain is
    # rebuilt, then return unchanged — a storage artifact, not a change in the market. Carrying
    # the last directly observed reading across the lag keeps put/call on exactly the same
    # measure and calibration rather than dropping the component over it. Deliberately not a
    # different source: open interest spans 0.618-3.213 against a formula calibrated for
    # 0.591-1.362, so substituting it would fabricate signal at full confidence.
    put_call_basis = "observed" if pc is not None else None
    if pc is None and pending:
        carried, carried_day = last_observed_put_call(con, day)
        if carried is not None:
            pc, put_call_basis = carried, f"carried:{carried_day}"

    comps = score_components(vix, trend, fg, pc)
    weights = rcfg["weights"]
    avail = {k: w for k, w in weights.items() if k in comps}
    score = round(sum(comps[k] * w for k, w in avail.items()) / sum(avail.values()), 1) if avail else None
    confidence = "full" if len(comps) == 3 else ("partial" if comps else "stale")

    if oi and "pc_oi" in oi:
        oi_note = f"P/C(OI) {oi['pc_oi']}, total OI {oi['total_oi']:,} ({oi['source']})"
    elif oi:
        oi_note = f"nearest-expiry open interest not published yet ({oi['source']})"
    elif put_call_basis and put_call_basis.startswith("carried:"):
        oi_note = (f"put/call carried from {put_call_basis.split(':', 1)[1]}; "
                   "nearest-expiry volume not published yet")
    elif pending:
        oi_note = "put/call pending: nearest-expiry volume not published yet"
    else:
        oi_note = "options data unavailable"
    trend_text = f"{trend:+}" if trend is not None else "n/a"
    raw = json.dumps({"components": comps, "options": oi, "errors": errors, "pending": pending,
                      "put_call_basis": put_call_basis})
    with con:
        con.execute(
            "INSERT OR REPLACE INTO regime VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (day, now, vix, trend, fg, pc, oi_note, score, confidence,
             rcfg["formula_version"], raw),
        )
        store.insert_event(
            con, source="regime", native_id=f"regime:{day}", ts=now, rank=0,
            author="market-data", type_="regime_snapshot",
            text=f"VIX {vix} (5d {trend_text}) | Fear/Greed {fg} | Put/Call(vol) {pc} | {oi_note} | score {score} ({confidence})"
            if score is not None else f"regime degraded: {errors + pending}",
            engagement={}, raw_ref="",
        )
        store.export_jsonl(con, "regime", day)
    util.log("market_regime", f"session {day}: vix={vix} trend={trend} fg={fg} pc={pc} score={score} conf={confidence} errors={errors} pending={pending}")
    # Health status is deliberately not the same axis as DB confidence. The row stays honestly
    # "partial" when put/call is absent, but a gap that exists only because Yahoo has not
    # published the chain's volume yet is not a fault the Dashboard should page on: a forced
    # retry cannot shorten it, and the next run refills it once Yahoo backfills. Require the
    # full invariant — put/call is the sole missing component and nothing hard failed — so a
    # second, real failure can never ride in under this status.
    health = "ok" if confidence == "full" else confidence
    if (health == "partial" and pending and not errors
            and sorted(comps) == ["fear_greed", "vix"]):
        health = "pending_session"
    # Publish when put/call was last actually observed. This is evidence for a human reading
    # the status file, not a gate: a wall-clock bound on it would page every Monday after a
    # long weekend, which is the very false alarm this change exists to remove. A genuine
    # outage is caught structurally instead — see the note in the Dashboard's regime block.
    # Keyed on a direct observation, not on `pc`: a carried reading fills the component but is
    # not a fresh sighting, and recording it as one would hide how long the lag has run.
    put_call_last_seen = now if oi else read_status().get("put_call_last_seen")
    write_status(
        health,
        confidence=confidence,
        available_components=sorted(comps),
        expected_components=["fear_greed", "put_call", "vix"],
        errors=errors,
        pending=pending,
        put_call_basis=put_call_basis,
        put_call_last_seen=put_call_last_seen,
        score=score,
    )
    return 1 if confidence == "stale" else 0


if __name__ == "__main__":
    sys.exit(main() or 0)
