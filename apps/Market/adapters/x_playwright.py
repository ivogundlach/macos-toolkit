"""X/Twitter adapter via Playwright — the ONLY X method (Firecrawl removed 2026-06-13).

Why Playwright (Chromium persistent context), not Firecrawl: Firecrawl returned only ~5
posts/profile with no scroll on this plan, so delivery-day-only ingest missed active accounts.
A logged-in Chromium session scrolls each profile back until it reaches tweets already in the
store -> zero miss between runs.

Why NOT Lightpanda (the playwright-cli skill's lightweight CDP backend): tested 2026-06-13 —
Lightpanda loads x.com but renders "Something went wrong" with 0 articles. X is a JS-heavy
authenticated SPA with bot detection, which the skill itself says to handle with a normal
Chromium session; Lightpanda also does not persist the authenticated login that deep-scroll
needs. Chromium persistent profile is the correct backend here.

ONE-TIME SETUP (at go-live, ~July 2026):
    PLAYWRIGHT_BROWSERS_PATH=~/Library/Caches/ms-playwright \
      venv/bin/python adapters/x_playwright.py --login
  A browser opens; log into x.com once. The session persists in state/x_profile/ (0700).

TIMESTAMP SOURCE (fixed 2026-07-03): X's profile <article> nodes no longer contain a
<time datetime> element at all (verified logged-IN — not a logged-out artifact). Post time is
decoded from the tweet SNOWFLAKE id instead (ts_from_status_id): exact, DOM-independent, can't
regress with X's markup. The old <time> read remains only as a last-ditch fallback.

INGEST GUARDS: a post whose id won't decode is SKIPPED (never stamped "now"); posts older than
MAX_POST_AGE_DAYS are SKIPPED (X often surfaces months-old "top"/pinned posts atop a profile);
a run that skips everything with zero kept logs a loud "session likely logged out — run --login"
warning instead of quietly polluting the store.
"""
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pipeline"))
import store
import util

os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", os.path.expanduser("~/Library/Caches/ms-playwright"))
PROFILE_DIR = os.path.join(store.ROOT, "state", "x_profile")
STATUS_RE = re.compile(r"/([^/]+)/status/(\d+)")
CASHTAG_RE = re.compile(r"\$([A-Z]{1,5})\b")
MAX_SCROLLS = 40
EMPTY_PROFILE_RETRY_DELAY_MS = 12_000
MAX_POST_AGE_DAYS = 30  # complete rolling evidence window; authentication is validated separately
SNOWFLAKE_EPOCH_MS = 1288834974657  # Twitter/X snowflake epoch (2010-11-04T01:42:54.657Z)
STATUS_FILENAME = (
    "x_scrape_status.json"
    if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1"
    else "x_scrape_status.interactive.json"
)
STATUS_PATH = os.path.join(store.ROOT, "state", STATUS_FILENAME)
AUTH_STATUS_FILENAME = (
    "x_auth_status.json"
    if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1"
    else "x_auth_status.interactive.json"
)
AUTH_STATUS_PATH = os.path.join(store.ROOT, "state", AUTH_STATUS_FILENAME)


def _write_status(path, status, **fields):
    payload = {
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "execution_context": "background" if os.environ.get("MARKET_BACKGROUND_CONTEXT") == "1" else "interactive",
        "status": status,
        "window_days": MAX_POST_AGE_DAYS,
        **fields,
    }
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def write_status(status, **fields):
    _write_status(STATUS_PATH, status, **fields)


def write_auth_status(status, **fields):
    _write_status(AUTH_STATUS_PATH, status, **fields)


def ts_from_status_id(status_id):
    """Exact post time decoded from the tweet snowflake id (top 41 bits = ms since the X
    epoch). Robust to DOM changes — X stopped rendering a <time datetime> element in profile
    <article>s (verified 2026-07-03), so we no longer depend on it. Returns UTC ISO-8601 or None."""
    try:
        ms = (int(status_id) >> 22) + SNOWFLAKE_EPOCH_MS
    except (TypeError, ValueError):
        return None
    # snowflake ids only exist from 2010 on; a value before the epoch is not a real id
    if ms < SNOWFLAKE_EPOCH_MS:
        return None
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(timespec="seconds")


def _fresh_ts(ts):
    """Return the parsed-ok, recent-enough timestamp or None (skip the post)."""
    if not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if datetime.now(timezone.utc) - dt > timedelta(days=MAX_POST_AGE_DAYS):
        return None
    return ts


def _context(p, headless=True):
    os.makedirs(PROFILE_DIR, exist_ok=True)
    os.chmod(PROFILE_DIR, 0o700)
    # No custom user_agent: a hardcoded stale UA (Chrome/124, from 2024) mismatched the
    # actual browser and got the imported session revoked server-side (2026-07-03). The
    # bundled Chromium's own UA is always version-coherent. AutomationControlled off so
    # navigator.webdriver doesn't flag the session.
    return p.chromium.launch_persistent_context(
        PROFILE_DIR, headless=headless,
        args=["--disable-blink-features=AutomationControlled"],
        locale="en-US",
        viewport={"width": 1280, "height": 1600})


def _context_with_cookies(p, injected):
    context = _context(p, headless=True)
    if injected:
        context.clear_cookies()
        context.add_cookies(injected)
    return context


def login():
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        ctx = _context(p, headless=False)
        page = ctx.new_page()
        page.goto("https://x.com/login", timeout=60000)
        print("Log into X in the browser window, then press Enter here...")
        input()
        ctx.close()
        print(f"session saved to {PROFILE_DIR}")


SAFARI_COOKIES = os.path.expanduser(
    "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")


def _safari_x_cookies():
    """Parse Safari's binarycookies store and return the exact .x.com cookie set."""
    import struct
    data = open(SAFARI_COOKIES, "rb").read()
    if data[:4] != b"cook":
        raise RuntimeError("not a binarycookies file")
    npages = struct.unpack(">i", data[4:8])[0]
    sizes = [struct.unpack(">i", data[8 + 4 * i:12 + 4 * i])[0] for i in range(npages)]
    off = 8 + 4 * npages
    out = []
    for size in sizes:
        page = data[off:off + size]
        off += size
        n = struct.unpack("<i", page[4:8])[0]
        for i in range(n):
            co = struct.unpack("<i", page[8 + 4 * i:12 + 4 * i])[0]
            c = page[co:]
            flags = struct.unpack("<i", c[8:12])[0]
            offs = [struct.unpack("<i", c[o:o + 4])[0] for o in (16, 20, 24, 28)]

            def rd(o):
                return c[o:c.index(b"\x00", o)].decode("utf-8", "replace")

            dom, name, pth, val = rd(offs[0]), rd(offs[1]), rd(offs[2]), rd(offs[3])
            if dom in (".x.com", "x.com"):  # EXACT domain — suffix matching pulls in fox/box/dropbox
                out.append({"name": name, "value": val, "domain": ".x.com",
                            "path": pth or "/", "secure": True,
                            "httpOnly": bool(flags & 4), "sameSite": "None"})
    return out


def import_safari():
    """Copy Ivo's live x.com session straight from Safari's cookie store into the scraper
    profile — no login flow (rate-limit-proof), no manual cookie copying. Import the FULL
    x.com set: a partial session (auth_token alone) from an incoherent fingerprint got
    revoked server-side on 2026-07-03. Verifies on a real PROFILE page (not just /home)
    that the session sticks and posts are fresh."""
    from playwright.sync_api import sync_playwright
    cookies = _safari_x_cookies()
    names = sorted(c["name"] for c in cookies)
    if not any(c["name"] == "auth_token" for c in cookies):
        print(f"Safari has no x.com auth_token (found: {names}) — log into x.com in Safari first")
        return 1
    print(f"importing from Safari: {names}")
    with sync_playwright() as p:
        ctx = _context(p, headless=True)
        ctx.clear_cookies()
        ctx.add_cookies(cookies)
        page = ctx.new_page()
        page.goto("https://x.com/home", timeout=60000)
        page.wait_for_timeout(5000)
        cfg = store.config()
        handle = cfg["sources"]["x_tier1"]["handles"][0]
        page.goto(f"https://x.com/{handle}", timeout=60000)
        page.wait_for_timeout(8000)
        ok = page.query_selector(
            "a[data-testid='SideNav_NewTweet_Button'], a[href='/compose/post']") is not None
        ctx.close()
    if ok:
        print(f"logged-in session imported + verified on @{handle} -> {PROFILE_DIR}")
        return 0
    print("import FAILED — profile page did not render as logged-in")
    return 1


def import_cookies():
    """Bypass the login flow entirely (X rate-limits login attempts from fresh automated
    profiles regardless of IP/VPN — hit 2026-07-03). Paste the `auth_token` cookie from any
    browser where Ivo is already logged into x.com; the session lands in the same persistent
    profile the scraper uses. Verifies by loading /home."""
    import getpass
    from playwright.sync_api import sync_playwright
    print("From a logged-in browser (Safari: Develop > Show Web Inspector > Storage > Cookies")
    print("> x.com), copy the cookie VALUES. Input is hidden; paste + Enter.")
    auth = getpass.getpass("auth_token (required): ").strip()
    if not auth:
        print("no auth_token given; aborting")
        return 1
    ct0 = getpass.getpass("ct0 (optional, Enter to skip): ").strip()
    cookies = [{"name": "auth_token", "value": auth, "domain": ".x.com", "path": "/",
                "secure": True, "httpOnly": True, "sameSite": "None"}]
    if ct0:
        cookies.append({"name": "ct0", "value": ct0, "domain": ".x.com", "path": "/",
                        "secure": True, "httpOnly": False, "sameSite": "Lax"})
    with sync_playwright() as p:
        ctx = _context(p, headless=True)
        ctx.add_cookies(cookies)
        page = ctx.new_page()
        page.goto("https://x.com/home", timeout=60000)
        page.wait_for_timeout(5000)
        ok = "/home" in page.url and page.query_selector(
            "a[data-testid='SideNav_NewTweet_Button'], a[href='/compose/post']") is not None
        ctx.close()
    if ok:
        print(f"logged-in session imported OK -> {PROFILE_DIR}")
        return 0
    print("import FAILED — /home did not load as logged-in. Re-copy auth_token "
          "(it may have rotated) and retry.")
    return 1


def known_ids(con, handle):
    rows = con.execute("SELECT event_id FROM events WHERE source LIKE 'x_%' AND author=?", (handle,))
    return {r[0] for r in rows}


def article_status_id(article, handle):
    """Return only a status authored by the configured profile, not quotes/reposts."""
    for anchor in article.query_selector_all("a[href*='/status/']"):
        match = STATUS_RE.search(anchor.get_attribute("href") or "")
        if match and match.group(1).casefold() == handle.casefold():
            return match.group(2)
    return None


def scrape_profile(page, handle, con, source, rank):
    """Return collected posts plus enough observations to distinguish inactivity from failure."""
    page.goto(f"https://x.com/{handle}", timeout=60000)
    page.wait_for_timeout(6000)  # let the logged-in timeline hydrate before reading articles
    seen_ids = known_ids(con, handle)
    collected, skipped, observed, stalls, last_count = {}, 0, set(), 0, 0
    known_boundary_stalls = 0
    for _ in range(MAX_SCROLLS):
        known_this_scroll = 0
        new_this_scroll = 0
        for art in page.query_selector_all("article"):
            try:
                text = art.inner_text()
            except Exception:
                continue
            status_id = article_status_id(art, handle)
            if not status_id:
                continue
            observed.add(status_id)
            eid = store.event_id(source, status_id)
            if eid in seen_ids:
                known_this_scroll += 1
                continue
            if status_id in collected:
                continue
            # exact time from the snowflake id (X no longer ships <time datetime>; fall back
            # to it only if the id somehow won't decode)
            ts_el = art.query_selector("time")
            raw_ts = ts_from_status_id(status_id) or (
                ts_el.get_attribute("datetime") if ts_el else None)
            ts = _fresh_ts(raw_ts)
            if ts is None:  # unparseable, or older than the freshness window — never stamp now()
                skipped += 1
                continue
            collected[status_id] = {
                "ts": ts,
                "text": text.strip()[:8000],
                "tickers": CASHTAG_RE.findall(text),
                "urls": [f"https://x.com/{handle}/status/{status_id}"]}
            new_this_scroll += 1
        if new_this_scroll:
            known_boundary_stalls = 0
        elif known_this_scroll or known_boundary_stalls:
            # Once the durable boundary is seen, inspect one additional scroll.
            # A newly rendered post resets it; a virtualized older page completes it.
            known_boundary_stalls += 1
        page.mouse.wheel(0, 4000)
        page.wait_for_timeout(1500)
        stalls = stalls + 1 if len(observed) == last_count else 0
        last_count = len(observed)
        if stalls >= 4:  # no new posts after repeated scrolls
            break
        if known_boundary_stalls >= 2:
            break  # existing IDs prove older timeline coverage is already durable
    newest_observed = max(
        (value for value in (ts_from_status_id(status_id) for status_id in observed) if value),
        default=None,
    )
    return collected, skipped, len(observed), newest_observed


def empty_page_diagnostic(page):
    """Small non-content diagnostic for X error/rate-limit pages."""
    messages = []
    for selector in ("[data-testid='error-detail']", "[role='alert']"):
        try:
            for element in page.query_selector_all(selector)[:3]:
                message = re.sub(r"\s+", " ", element.inner_text()).strip()[:240]
                if message and message not in messages:
                    messages.append(message)
        except Exception:
            continue
    try:
        title = page.title()[:160]
    except Exception:
        title = ""
    return {"url": page.url[:300], "title": title, "messages": messages}


def scrape_profile_with_retry(page, handle, con, source, rank, retry_page_factory=None):
    result = scrape_profile(page, handle, con, source, rank)
    if result[2] != 0:
        return (*result, False)
    util.log(
        "x_playwright",
        f"@{handle}: rendered no posts; retrying once after hydration cooldown",
    )
    page.wait_for_timeout(EMPTY_PROFILE_RETRY_DELAY_MS)
    if retry_page_factory is not None:
        page.close()
        page = retry_page_factory()
    return (*scrape_profile(page, handle, con, source, rank), True)


def scrape_profile_isolated(p, injected, handle, con, source, rank):
    """Use a new browser process per profile and per empty-profile retry."""
    context = _context_with_cookies(p, injected)
    try:
        page = context.new_page()
        result = scrape_profile(page, handle, con, source, rank)
        retried_empty = False
        if result[2] == 0:
            util.log(
                "x_playwright",
                f"@{handle}: rendered no posts; relaunching browser once after hydration cooldown",
            )
            page.wait_for_timeout(EMPTY_PROFILE_RETRY_DELAY_MS)
            context.close()
            context = _context_with_cookies(p, injected)
            page = context.new_page()
            result = scrape_profile(page, handle, con, source, rank)
            retried_empty = True
        diagnostic = empty_page_diagnostic(page) if result[2] == 0 else None
        return (*result, retried_empty, diagnostic)
    finally:
        context.close()


def main():
    if "--login" in sys.argv:
        login()
        return
    if "--import-safari" in sys.argv:
        sys.exit(import_safari())
    if "--import-cookies" in sys.argv:
        sys.exit(import_cookies())
    from playwright.sync_api import sync_playwright
    cfg = store.config()
    requested_handle = None
    if "--handle" in sys.argv:
        try:
            requested_handle = sys.argv[sys.argv.index("--handle") + 1].lstrip("@")
        except IndexError:
            print("--handle requires a profile name", file=sys.stderr)
            return 64
    con = store.connect()
    total = 0
    days = set()
    total_skipped = 0
    failed_handles = []
    handle_results = {}
    # Inject Ivo's LIVE Safari x.com session at the start of every run. X rotates/revokes
    # auth_token per-fingerprint, so a session saved in the persistent profile goes dead
    # between launches (verified 2026-07-03: import verifies logged-in, next run is logged
    # OUT and sees only months-old "top posts"). Safari holds the continuously-valid token,
    # so reading it fresh each run keeps the scrape logged in. Falls back to whatever the
    # profile still holds if Safari's store is unreadable.
    injected = None
    try:
        injected = _safari_x_cookies()
        if not any(c["name"] == "auth_token" for c in injected):
            injected = None
    except Exception as e:
        util.log("x_playwright", f"Safari cookie read failed ({e}); using saved profile session")
    with sync_playwright() as p:
        ctx = _context_with_cookies(p, injected)
        page = ctx.new_page()
        page.goto("https://x.com/home", timeout=60000)
        # A fixed 5s sleep + single query produced FALSE "auth_required" on a valid
        # session (verified 2026-07-23: Safari auth_token injected, page fully logged
        # in, selector present — just queried before X finished rendering). That sent
        # Ivo to re-login repeatedly for nothing. Wait for the marker instead, and
        # accept several markers so one testid rename can't fake a logged-out state.
        authenticated = True
        try:
            page.wait_for_selector(
                "a[data-testid='SideNav_NewTweet_Button'], a[href='/compose/post'], "
                "[data-testid='SideNav_AccountSwitcher_Button'], "
                "[data-testid='AppTabBar_Home_Link']",
                timeout=30000,
            )
        except Exception:
            authenticated = False
        if not authenticated:
            ctx.close()
            writer = write_auth_status if "--check-auth" in sys.argv else write_status
            writer(
                "auth_required",
                cause="X session is not authenticated; the background process could not use Safari cookies.",
                safari_cookie_injected=bool(injected),
            )
            util.log("x_playwright", "ERROR: X authentication unavailable; refusing logged-out timeline data")
            return 2
        if "--check-auth" in sys.argv:
            ctx.close()
            write_auth_status(
                "ok",
                authentication_only=True,
                safari_cookie_injected=bool(injected),
            )
            util.log("x_playwright", "X authentication check passed")
            return 0
        ctx.close()
        for source in ("x_tier1", "x_tier2"):
            scfg = cfg["sources"][source]
            if not scfg.get("enabled"):
                continue
            for handle in scfg["handles"]:
                if requested_handle and handle.casefold() != requested_handle.casefold():
                    continue
                try:
                    posts, skipped, observed, newest_observed, retried_empty, diagnostic = (
                        scrape_profile_isolated(p, injected, handle, con, source, scfg["rank"])
                    )
                except Exception as e:
                    util.log("x_playwright", f"@{handle} FAILED: {e}")
                    failed_handles.append(handle)
                    continue
                handle_results[handle] = {
                    "new_events": len(posts),
                    "observed_posts": observed,
                    "newest_observed": newest_observed,
                    "skipped": skipped,
                    "empty_retry_attempted": retried_empty,
                }
                if observed == 0:
                    handle_results[handle]["page_diagnostic"] = diagnostic
                    util.log("x_playwright", f"@{handle} FAILED: profile rendered no posts")
                    failed_handles.append(handle)
                    continue
                total_skipped += skipped
                with con:
                    for sid, pdata in posts.items():
                        total += store.insert_event(
                            con, source=source, native_id=sid, ts=pdata["ts"],
                            rank=scfg["rank"], author=handle, type_="post",
                            text=pdata["text"], tickers=pdata["tickers"],
                            urls=pdata["urls"], engagement={}, raw_ref="")
                        days.add(store.session_date(pdata["ts"]))
                util.log(
                    "x_playwright",
                    f"@{handle}: {len(posts)} new, {observed} observed, newest={newest_observed}, "
                    f"{skipped} skipped (no-ts/stale)",
                )
    with con:
        for source in ("x_tier1", "x_tier2"):
            for day in days:
                store.export_jsonl(con, source, day)
    expected_handles = sum(
        sum(
            1 for handle in cfg["sources"][source]["handles"]
            if not requested_handle or handle.casefold() == requested_handle.casefold()
        )
        for source in ("x_tier1", "x_tier2")
        if cfg["sources"][source].get("enabled")
    )
    if requested_handle and expected_handles == 0:
        write_status("configuration_error", requested_handle=requested_handle)
        util.log("x_playwright", f"ERROR: @{requested_handle} is not a configured enabled handle")
        return 64
    if failed_handles:
        write_status(
            "partial_failure", new_events=total, skipped=total_skipped,
            safari_cookie_injected=bool(injected), handles_checked=len(handle_results),
            handles_expected=expected_handles, failed_handles=failed_handles,
            handle_results=handle_results,
        )
        util.log("x_playwright", f"ERROR: failed handles: {', '.join(failed_handles)}")
        return 3
    util.log("x_playwright", f"done: {total} new events")
    write_status(
        "ok", new_events=total, skipped=total_skipped,
        safari_cookie_injected=bool(injected), handles_checked=len(handle_results),
        handles_expected=expected_handles, handle_results=handle_results,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
