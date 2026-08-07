"""Unit tests for x_playwright timestamp handling. Run: python3 tests/test_x_adapter.py
No browser/network — pure functions only."""
import os
import sys
import time
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "adapters"))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))
import x_playwright as xp

PASS, FAIL = [], []


def check(name, cond):
    (PASS if cond else FAIL).append(name)
    print(("  ok  " if cond else " FAIL ") + name)


# snowflake decode: known ids -> known UTC times (X snowflake epoch 2010-11-04)
check("snowflake: known id decodes to Nov 2025",
      xp.ts_from_status_id("1985768197157437805") == "2025-11-04T17:56:46+00:00")
check("snowflake: first-ever snowflake ~ epoch",
      xp.ts_from_status_id("1").startswith("2010-11-04"))
check("snowflake: non-numeric -> None", xp.ts_from_status_id("notanid") is None)
check("snowflake: None -> None", xp.ts_from_status_id(None) is None)
check("snowflake: id decoding into the future still returns a value (guard is age, not this)",
      xp.ts_from_status_id(str(1 << 62)) is not None)

# _fresh_ts freshness window
now = datetime.now(timezone.utc)
recent = (now - timedelta(days=1)).isoformat()
old = (now - timedelta(days=xp.MAX_POST_AGE_DAYS + 5)).isoformat()
check("_fresh_ts: recent kept", xp._fresh_ts(recent) == recent)
check("_fresh_ts: stale dropped", xp._fresh_ts(old) is None)
check("_fresh_ts: None dropped", xp._fresh_ts(None) is None)
check("_fresh_ts: garbage dropped", xp._fresh_ts("not-a-date") is None)

# integration of the two: a months-old real tweet id is decoded THEN dropped by the guard
old_id_ts = xp.ts_from_status_id("1985768197157437805")  # 2025-11-04, >14d ago
check("decode+guard: months-old id decodes but fails freshness",
      old_id_ts is not None and xp._fresh_ts(old_id_ts) is None)


class FakeAnchor:
    def __init__(self, href):
        self.href = href

    def get_attribute(self, _name):
        return self.href


class FakeArticle:
    def query_selector_all(self, _selector):
        return [
            FakeAnchor("/quoted/status/100"),
            FakeAnchor("/Example/status/200"),
        ]


check("article identity: ignores quoted/reposted authors",
      xp.article_status_id(FakeArticle(), "example") == "200")


recent_status_id = str(
    (int(time.time() * 1000) - xp.SNOWFLAKE_EPOCH_MS) << 22
)


class KnownArticle:
    def inner_text(self):
        return "known post"

    def query_selector_all(self, _selector):
        return [FakeAnchor(f"/example/status/{recent_status_id}")]

    def query_selector(self, _selector):
        return None


class FakeMouse:
    def wheel(self, *_args):
        pass


class KnownBoundaryPage:
    def __init__(self):
        self.mouse = FakeMouse()
        self.article_queries = 0

    def goto(self, *_args, **_kwargs):
        pass

    def wait_for_timeout(self, _value):
        pass

    def query_selector_all(self, selector):
        if selector == "article":
            self.article_queries += 1
            return [KnownArticle()]
        return []


class KnownConnection:
    def execute(self, *_args):
        return [(xp.store.event_id("x_tier1", recent_status_id),)]


known_page = KnownBoundaryPage()
known_result = xp.scrape_profile(
    known_page, "example", KnownConnection(), "x_tier1", 1
)
check("known boundary: stops after confirmed durable post",
      known_result[2] == 1 and known_page.article_queries == 2)


class FakePage:
    url = "https://x.com/example"

    def __init__(self):
        self.waits = []

    def wait_for_timeout(self, value):
        self.waits.append(value)

    def query_selector_all(self, _selector):
        return []

    def title(self):
        return "X"

    def close(self):
        self.closed = True


page = FakePage()
original_scrape = xp.scrape_profile
original_log = xp.util.log
sequence = iter([
    ({}, 0, 0, None),
    ({"post": {"ts": recent}}, 0, 1, recent),
])
xp.scrape_profile = lambda *_args: next(sequence)
xp.util.log = lambda *_args: None
try:
    retried = xp.scrape_profile_with_retry(page, "example", None, "x_tier1", 1)
finally:
    xp.scrape_profile = original_scrape
    xp.util.log = original_log
check("zero-render: retries once and accepts recovered profile",
      retried[2] == 1 and retried[4] is True
      and page.waits == [xp.EMPTY_PROFILE_RETRY_DELAY_MS])
first_page = FakePage()
replacement_page = FakePage()
sequence = iter([
    ({}, 0, 0, None),
    ({"post": {"ts": recent}}, 0, 1, recent),
])
xp.scrape_profile = lambda page_arg, *_args: (
    next(sequence) if page_arg in (first_page, replacement_page) else None
)
xp.util.log = lambda *_args: None
try:
    isolated_retry = xp.scrape_profile_with_retry(
        first_page, "example", None, "x_tier1", 1, lambda: replacement_page
    )
finally:
    xp.scrape_profile = original_scrape
    xp.util.log = original_log
check("zero-render: retry replaces the browser page when a factory is provided",
      isolated_retry[2] == 1 and getattr(first_page, "closed", False))


class FakeContext:
    def __init__(self, page):
        self.page = page
        self.closed = False

    def new_page(self):
        return self.page

    def close(self):
        self.closed = True


contexts = [FakeContext(FakePage()), FakeContext(FakePage())]
context_sequence = iter(contexts)
result_sequence = iter([
    ({}, 0, 0, None),
    ({"post": {"ts": recent}}, 0, 1, recent),
])
original_context_with_cookies = xp._context_with_cookies
xp._context_with_cookies = lambda *_args: next(context_sequence)
xp.scrape_profile = lambda *_args: next(result_sequence)
xp.util.log = lambda *_args: None
try:
    process_isolated = xp.scrape_profile_isolated(
        object(), [], "example", None, "x_tier1", 1
    )
finally:
    xp._context_with_cookies = original_context_with_cookies
    xp.scrape_profile = original_scrape
    xp.util.log = original_log
check("zero-render: isolated retry relaunches the browser context",
      process_isolated[2] == 1 and process_isolated[4] is True
      and all(context.closed for context in contexts))
check("zero-render: non-content diagnostics are bounded",
      xp.empty_page_diagnostic(page) == {
          "url": "https://x.com/example", "title": "X", "messages": [],
      })

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
sys.exit(1 if FAIL else 0)
