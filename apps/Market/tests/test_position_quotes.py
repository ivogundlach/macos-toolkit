"""Deterministic tests for the schema-v6 weekly-close updater.

All fixtures use temporary SQLite files and an in-process Yahoo response; the live Market
database is never opened for writing.
"""

import datetime as dt
import json
import os
import sqlite3
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pipeline"))

import migrate
import position_quotes as quotes


PASS = []
FAIL = []


def check(name, condition):
    (PASS if condition else FAIL).append(name)
    print(("  ok  " if condition else " FAIL ") + name)


class Response:
    def __init__(self, payload):
        self.data = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, *args):
        return self.data


def payload(symbol, market_date, close=123.45, currency="USD", duplicate=False):
    day = dt.datetime.fromisoformat(market_date).replace(tzinfo=dt.timezone(dt.timedelta(hours=-4)))
    timestamps = [int(day.timestamp())]
    closes = [close]
    if duplicate:
        timestamps.append(timestamps[0] + 3600)
        closes.append(close + 1)
    return {
        "chart": {
            "result": [{
                "meta": {"symbol": symbol, "currency": currency},
                "timestamp": timestamps,
                "indicators": {"quote": [{"close": closes}]},
            }],
            "error": None,
        }
    }


class Sandbox:
    def __enter__(self):
        self.root = tempfile.mkdtemp(prefix="market-quotes-")
        os.makedirs(os.path.join(self.root, "state"))
        self.db = os.path.join(self.root, "state", "market.sqlite")
        self.con = sqlite3.connect(self.db)
        self.con.executescript(
            "CREATE TABLE positions (symbol TEXT NOT NULL, quantity TEXT NOT NULL, currency TEXT NOT NULL);"
            + migrate.DDL_V6
        )
        self.con.commit()
        return self

    def __exit__(self, *args):
        self.con.close()
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(self.db + suffix)
            except FileNotFoundError:
                pass
        try:
            os.remove(os.path.join(self.root, "state", ".position_quotes.lock"))
        except FileNotFoundError:
            pass
        os.rmdir(os.path.join(self.root, "state"))
        os.rmdir(self.root)

    def add(self, symbol, quantity="1", currency="USD", cost_basis="10"):
        self.con.execute(
            "INSERT INTO positions(symbol,quantity,currency) VALUES (?,?,?)",
            (symbol, quantity, currency),
        )
        self.con.commit()

    def rows(self):
        return self.con.execute("SELECT * FROM position_quotes ORDER BY symbol,currency").fetchall()


def test_timing_and_calendar():
    before = dt.datetime(2026, 8, 7, 21, 14, tzinfo=dt.timezone.utc)
    at = dt.datetime(2026, 8, 7, 21, 15, tzinfo=dt.timezone.utc)
    monday = dt.datetime(2026, 8, 3, 12, tzinfo=dt.timezone.utc)
    check("cutoff before 17:15 targets prior Friday", quotes.quote_target(before) == ("2026-07-31", "2026-07-31"))
    check("cutoff at 17:15 targets current Friday", quotes.quote_target(at) == ("2026-08-07", "2026-08-07"))
    check("Monday before cutoff remains prior Friday", quotes.quote_target(monday) == ("2026-07-31", "2026-07-31"))
    # 2025-07-04 is an XNYS holiday; the weekly bucket remains Friday while the market date is Thursday.
    check("Friday holiday stores actual prior session", quotes.expected_market_date("2025-07-04").isoformat() == "2025-07-03")


def test_exact_session_parsing():
    good = quotes.parse_chart_payload(payload("ACME", "2026-07-31"), "2026-07-31", "ACME")
    check("exact session parser accepts one positive close", good.outcome == "ok" and good.close_price == 123.45)
    try:
        quotes.parse_chart_payload(payload("ACME", "2026-07-31", duplicate=True), "2026-07-31", "ACME")
        duplicate = False
    except quotes.QuoteError as exc:
        duplicate = exc.code == "duplicate_session_bar"
    check("duplicate exact-session bars are transient", duplicate)
    try:
        quotes.parse_chart_payload(payload("OTHER", "2026-07-31"), "2026-07-31", "ACME")
        identity = False
    except quotes.QuoteError as exc:
        identity = exc.code == "identity_mismatch"
    check("Yahoo identity mismatch is transient", identity)
    check("canonical decimal strips insignificant zeroes", quotes.canonical_decimal(123.4500) == "123.45")
    check("canonical decimal expands exponent notation", quotes.canonical_decimal("1.20e2") == "120")


def test_fetch_and_cache_preservation():
    with Sandbox() as sb:
        sb.add(" ACME ")
        now = dt.datetime(2026, 8, 1, 12, tzinfo=dt.timezone.utc)
        calls = []

        def opener(request, timeout):
            calls.append((request.full_url, timeout))
            return Response(payload("ACME", "2026-07-31"))

        first = quotes.run(db_path=sb.db, root=sb.root, now=now, opener=opener)
        second = quotes.run(db_path=sb.db, root=sb.root, now=now, opener=opener)
        row = sb.rows()[0]
        close_type = sb.con.execute(
            "SELECT typeof(close_price) FROM position_quotes WHERE symbol='ACME'"
        ).fetchone()[0]
        check("successful weekly close is committed as canonical text", first["committed"] == 1 and row[2] == "123.45")
        check("SQLite stores close_price with TEXT affinity", close_type == "text")
        check("matching successful week does not refetch", second["attempted"] == 0 and len(calls) == 1)

        # Rollover to a new target; an HTTP error must preserve the prior cached quote.
        def failed(request, timeout):
            raise OSError("offline")

        rollover = dt.datetime(2026, 8, 8, 12, tzinfo=dt.timezone.utc)
        result = quotes.run(db_path=sb.db, root=sb.root, now=rollover, opener=failed)
        row2 = sb.rows()[0]
        check("transient rollover is attempted", result["attempted"] == 1 and row2[7] == "transient_error")
        check("transient failure preserves prior cache", row2[2] == "123.45" and row2[3] == "2026-07-31")
        check("transient failure sets positive bounded backoff", row2[11] == 1 and row2[12])


def test_unsupported_and_batching():
    with Sandbox() as sb:
        sb.add("bad symbol")
        sb.add("AAA")
        sb.add("BBB")
        sb.add("EURX", currency="EUR")
        now = dt.datetime(2026, 8, 1, 12, tzinfo=dt.timezone.utc)

        def opener(request, timeout):
            symbol = request.full_url.split("/chart/")[1].split("?")[0]
            return Response(payload(symbol, "2026-07-31"))

        first = quotes.run(db_path=sb.db, root=sb.root, now=now, opener=opener)
        rows = sb.rows()
        unsupported = [r for r in rows if r[0] == "BAD SYMBOL"]
        check("bounded batch fetches at most two eligible symbols", first["attempted"] == 2)
        check("deterministic invalid syntax is unsupported", unsupported and unsupported[0][7] == "unsupported")
        eur = next(r for r in rows if r[1] == "EUR")
        check("non-USD position is unsupported", eur[7] == "unsupported" and eur[11] == 0 and eur[12] is None)
        before = sb.rows()
        second = quotes.run(db_path=sb.db, root=sb.root, now=now, opener=opener)
        check("unchanged unsupported rows are not rewritten", second["attempted"] == 0 and sb.rows() == before)


def test_schema_checks_and_lock():
    with Sandbox() as sb:
        checks = [
            ("INSERT INTO position_quotes VALUES ('A','USD','not-a-decimal','2026-07-31','2026-07-31','2026-08-01','x','ok','2026-07-31','2026-08-01',NULL,0,NULL)", False),
            ("INSERT INTO position_quotes VALUES ('A','USD','123.4500','2026-07-31','2026-07-31','2026-08-01','x','ok','2026-07-31','2026-08-01',NULL,0,NULL)", True),
            ("INSERT INTO position_quotes VALUES ('A','USD',NULL,NULL,NULL,NULL,NULL,'transient_error','2026-07-31','2026-08-01','x',1,'2026-08-01T01:00:00Z')", True),
        ]
        for sql, expected in checks:
            try:
                sb.con.execute(sql)
                sb.con.rollback()
                accepted = True
            except sqlite3.IntegrityError:
                sb.con.rollback()
                accepted = False
            check("schema check rejects/accepts expected tuple", accepted == expected)

        with quotes.quote_lock(sb.root) as first:
            with quotes.quote_lock(sb.root) as second:
                check("quote lock is nonblocking and exclusive", first and not second)


if __name__ == "__main__":
    test_timing_and_calendar()
    test_exact_session_parsing()
    test_fetch_and_cache_preservation()
    test_unsupported_and_batching()
    test_schema_checks_and_lock()
    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        for failure in FAIL:
            print("  FAILED:", failure)
        raise SystemExit(1)
    print("position quotes: all tests pass")
