"""Bounded weekly-close quote updater for held Market positions.

The updater deliberately owns only the latest state for each canonical position key.  It
does not stream prices and it never writes to the positions table: the canonical store is
read, Yahoo is queried outside SQLite transactions, and each result is committed with a
short conditional transaction.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import errno
import fcntl
import json
import math
import os
import re
import sqlite3
import sys
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Callable, Iterable, Optional
from zoneinfo import ZoneInfo

import exchange_calendars as xcals


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NY = ZoneInfo("America/New_York")
UTC = _dt.timezone.utc
CAL = xcals.get_calendar("XNYS")

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36"
YAHOO_CHART = "https://query1.finance.yahoo.com/v8/finance/chart/{}"
MAX_BODY_BYTES = 2 * 1024 * 1024
HTTP_TIMEOUT = 15
MAX_SYMBOLS_PER_RUN = 2
BACKOFF_BASE_SECONDS = 15 * 60
BACKOFF_MAX_SECONDS = 6 * 60 * 60
ERROR_CODE_MAX = 96
WEEKLY_CUTOFF = _dt.time(17, 15)

# A local symbol is intentionally narrower than an arbitrary URL path.  Yahoo's direct
# symbols use letters, digits and a small set of punctuation; a single dotted suffix is
# accepted only as share-class notation (BRK.B -> BRK-B).
_SYMBOL_RE = re.compile(r"^[A-Z0-9][A-Z0-9_+=\-\.\^]{0,31}$")
_SHARE_CLASS_RE = re.compile(r"^[A-Z0-9]+\.[A-Z0-9]{1,3}$")
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


class QuoteError(Exception):
    """A fetch/parse error that is retryable and has a bounded database code."""

    def __init__(self, code: str, message: str = ""):
        self.code = _bounded_error_code(code)
        super().__init__(message or self.code)


@dataclass(frozen=True)
class FetchResult:
    outcome: str
    close_price: Optional[float] = None
    market_date: Optional[str] = None
    source: Optional[str] = None
    error_code: Optional[str] = None


@dataclass(frozen=True)
class PositionKey:
    symbol: str
    currency: str


@dataclass(frozen=True)
class QuoteRow:
    symbol: str
    currency: str
    close_price: Optional[str]
    week_ending: Optional[str]
    market_date: Optional[str]
    fetched_at: Optional[str]
    source: Optional[str]
    fetch_outcome: str
    target_week_ending: str
    last_attempt_at: str
    last_error_code: Optional[str]
    failure_count: int
    retry_after: Optional[str]


def _bounded_error_code(value: Any) -> str:
    text = str(value or "error").strip().replace("\n", " ").replace("\r", " ")
    text = re.sub(r"\s+", "_", text)
    return (text[:ERROR_CODE_MAX] or "error")


def _as_ny(value: Optional[_dt.datetime]) -> _dt.datetime:
    if value is None:
        return _dt.datetime.now(UTC).astimezone(NY)
    if value.tzinfo is None:
        return value.replace(tzinfo=NY)
    return value.astimezone(NY)


def _as_utc(value: _dt.datetime) -> _dt.datetime:
    if value.tzinfo is None:
        value = value.replace(tzinfo=NY)
    return value.astimezone(UTC)


def _iso_utc(value: _dt.datetime) -> str:
    return _as_utc(value).isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse_iso(value: Any) -> Optional[_dt.datetime]:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = _dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def canonical_currency(value: Any) -> Optional[str]:
    """Return the canonical uppercase-trimmed currency key."""
    text = str(value or "").strip().upper()
    return text if text else None


def _canonical_key_symbol(value: Any) -> Optional[str]:
    """Canonicalize a held-position key before applying local Yahoo syntax rules."""
    text = str(value or "").strip().upper()
    return text if text else None


def canonical_symbol(value: Any) -> Optional[str]:
    """Return a canonical uppercase-trimmed local symbol, or ``None`` if invalid."""
    text = str(value or "").strip().upper()
    if not text or not _SYMBOL_RE.fullmatch(text):
        return None
    return text


def yahoo_symbol(value: Any) -> Optional[str]:
    """Map only dotted share-class notation to Yahoo's hyphen form."""
    symbol = canonical_symbol(value)
    if symbol is None:
        return None
    if "." not in symbol:
        return symbol
    if not _SHARE_CLASS_RE.fullmatch(symbol):
        return None
    return symbol.replace(".", "-")


def target_week_ending(now: Optional[_dt.datetime] = None) -> _dt.date:
    """Return the Friday whose weekly close is currently being acquired.

    The cutoff is evaluated in New York time, so a host configured for another timezone
    cannot move a quote into the wrong weekly bucket.  Saturday/Sunday and Friday after
    the cutoff refer to the current calendar week's Friday; Friday before the cutoff and
    Monday through Thursday refer to the preceding Friday.
    """
    local = _as_ny(now)
    most_recent_friday = local.date() - _dt.timedelta(days=(local.weekday() - 4) % 7)
    if local.weekday() == 4 and local.time() < WEEKLY_CUTOFF:
        most_recent_friday -= _dt.timedelta(days=7)
    return most_recent_friday


def expected_market_date(week_ending: _dt.date | str) -> _dt.date:
    """Choose the actual last XNYS session in the target Monday-Friday week."""
    if isinstance(week_ending, str):
        week_ending = _dt.date.fromisoformat(week_ending)
    monday = week_ending - _dt.timedelta(days=4)
    sessions = CAL.sessions_in_range(monday.isoformat(), week_ending.isoformat())
    if len(sessions) == 0:
        raise QuoteError("no_expected_session", "target week has no XNYS session")
    return sessions[-1].date()


def quote_target(now: Optional[_dt.datetime] = None) -> tuple[str, str]:
    week = target_week_ending(now)
    return week.isoformat(), expected_market_date(week).isoformat()


def _finite_positive(value: Any) -> Optional[float]:
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(result) or result <= 0:
        return None
    return result


def canonical_decimal(value: Any) -> Optional[str]:
    """Return a locale-independent, non-exponential positive decimal string.

    Yahoo supplies JSON numbers, which are validated as finite positive values first.  The
    persisted representation is then derived from ``str``/``Decimal`` rather than from a
    binary float formatting operation, with insignificant trailing zeroes removed.
    """
    try:
        decimal = Decimal(str(value).strip())
    except (InvalidOperation, TypeError, ValueError):
        return None
    if not decimal.is_finite() or decimal <= 0:
        return None
    text = format(decimal, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text if text else None


def _response_body(response: Any) -> bytes:
    try:
        data = response.read(MAX_BODY_BYTES + 1)
    except TypeError:
        data = response.read()
    if not isinstance(data, (bytes, bytearray)):
        raise QuoteError("malformed_response", "Yahoo response body was not bytes")
    if len(data) > MAX_BODY_BYTES:
        raise QuoteError("response_too_large", "Yahoo response exceeded 2 MiB")
    return bytes(data)


def parse_chart_payload(
    payload: Any,
    expected_date: _dt.date | str,
    request_symbol: str,
) -> FetchResult:
    """Validate one Yahoo chart payload and extract exactly one unadjusted close."""
    if isinstance(expected_date, str):
        expected_date = _dt.date.fromisoformat(expected_date)
    if not isinstance(payload, dict):
        raise QuoteError("malformed_response")
    chart = payload.get("chart")
    if not isinstance(chart, dict):
        raise QuoteError("malformed_response")
    if chart.get("error") not in (None, {}):
        raise QuoteError("remote_error")
    results = chart.get("result")
    if not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict):
        raise QuoteError("malformed_response")
    result = results[0]
    meta = result.get("meta")
    if not isinstance(meta, dict):
        raise QuoteError("malformed_response")
    returned_symbol = str(meta.get("symbol") or "").strip().upper()
    if returned_symbol != request_symbol.upper():
        raise QuoteError("identity_mismatch")
    currency = str(meta.get("currency") or "").strip().upper()
    if currency != "USD":
        raise QuoteError("currency_mismatch")

    timestamps = result.get("timestamp")
    indicators = result.get("indicators")
    if not isinstance(timestamps, list) or not isinstance(indicators, dict):
        raise QuoteError("malformed_response")
    quotes = indicators.get("quote")
    if not isinstance(quotes, list) or len(quotes) != 1 or not isinstance(quotes[0], dict):
        raise QuoteError("malformed_response")
    closes = quotes[0].get("close")
    if not isinstance(closes, list) or len(closes) != len(timestamps):
        raise QuoteError("malformed_response")

    matching: list[float] = []
    for timestamp, close in zip(timestamps, closes):
        try:
            ts = float(timestamp)
            if not math.isfinite(ts):
                raise ValueError
            day = _dt.datetime.fromtimestamp(ts, UTC).astimezone(NY).date()
        except (TypeError, ValueError, OverflowError, OSError):
            raise QuoteError("malformed_timestamp")
        if day == expected_date:
            parsed = _finite_positive(close)
            if parsed is None:
                raise QuoteError("invalid_close")
            matching.append(parsed)
    if len(matching) == 0:
        raise QuoteError("missing_session_bar")
    if len(matching) != 1:
        raise QuoteError("duplicate_session_bar")
    return FetchResult("ok", close_price=matching[0], market_date=expected_date.isoformat(), source="yahoo_chart")


def _url_for(symbol: str, expected_date: _dt.date) -> str:
    start = expected_date - _dt.timedelta(days=3)
    end = expected_date + _dt.timedelta(days=4)
    start_epoch = int(_dt.datetime.combine(start, _dt.time(), NY).timestamp())
    end_epoch = int(_dt.datetime.combine(end, _dt.time(), NY).timestamp())
    encoded = urllib.parse.quote(symbol, safe="")
    query = urllib.parse.urlencode(
        {"period1": start_epoch, "period2": end_epoch, "interval": "1d", "events": "history", "includeAdjustedClose": "false"}
    )
    return YAHOO_CHART.format(encoded) + "?" + query


def fetch_quote(
    request_symbol: str,
    expected_date: _dt.date | str,
    opener: Optional[Any] = None,
) -> FetchResult:
    """Fetch one bounded Yahoo chart request; all remote failures are transient."""
    if isinstance(expected_date, str):
        expected_date = _dt.date.fromisoformat(expected_date)
    request = urllib.request.Request(_url_for(request_symbol, expected_date), headers={"User-Agent": UA})
    open_fn: Callable[..., Any]
    if opener is None:
        open_fn = urllib.request.urlopen
    elif hasattr(opener, "open"):
        open_fn = opener.open
    else:
        open_fn = opener
    try:
        response = open_fn(request, timeout=HTTP_TIMEOUT)
        if hasattr(response, "__enter__"):
            with response:
                body = _response_body(response)
        else:
            body = _response_body(response)
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise QuoteError("malformed_response")
        return parse_chart_payload(payload, expected_date, request_symbol)
    except QuoteError:
        raise
    except urllib.error.HTTPError as exc:
        raise QuoteError(f"http_{exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise QuoteError("network_error") from exc
    except Exception as exc:  # malformed fixtures and remote protocol changes stay retryable
        raise QuoteError("network_error") from exc


def _decimal_nonzero(value: Any) -> bool:
    try:
        parsed = Decimal(str(value).strip())
    except (InvalidOperation, ValueError, TypeError):
        return False
    return parsed.is_finite() and parsed != 0


def _current_positions(con: sqlite3.Connection) -> set[PositionKey]:
    keys: set[PositionKey] = set()
    for raw_symbol, raw_currency, quantity in con.execute(
        "SELECT symbol, currency, quantity FROM positions"
    ):
        # Keep syntactically invalid but canonical nonblank symbols in the key set so
        # they can receive one durable `unsupported` attempt row instead of disappearing.
        symbol = _canonical_key_symbol(raw_symbol)
        currency = canonical_currency(raw_currency)
        if symbol and currency and _decimal_nonzero(quantity):
            keys.add(PositionKey(symbol, currency))
    return keys


def _read_quote_rows(con: sqlite3.Connection) -> dict[PositionKey, QuoteRow]:
    try:
        rows = con.execute(
            "SELECT symbol,currency,close_price,week_ending,market_date,fetched_at,source,"
            "fetch_outcome,target_week_ending,last_attempt_at,last_error_code,failure_count,retry_after "
            "FROM position_quotes"
        )
    except sqlite3.OperationalError:
        return {}
    out: dict[PositionKey, QuoteRow] = {}
    for row in rows:
        try:
            key = PositionKey(str(row[0]), str(row[1]))
            failure_count = int(row[11])
        except (TypeError, ValueError):
            continue
        out[key] = QuoteRow(
            key.symbol,
            key.currency,
            row[2],
            row[3],
            row[4],
            row[5],
            row[6],
            str(row[7]),
            str(row[8]),
            str(row[9]),
            row[10],
            max(0, failure_count),
            row[12],
        )
    return out


def _retry_due(row: QuoteRow, now: _dt.datetime, target: str) -> bool:
    if row.target_week_ending != target:
        return True
    if row.fetch_outcome in ("ok", "unsupported"):
        return False
    if row.fetch_outcome != "transient_error":
        return True
    retry = _parse_iso(row.retry_after)
    return retry is None or retry <= _as_utc(now)


def _backoff_seconds(failure_count: int) -> int:
    exponent = max(0, min(int(failure_count) - 1, 8))
    return min(BACKOFF_MAX_SECONDS, BACKOFF_BASE_SECONDS * (2**exponent))


def _retry_after(now: _dt.datetime, failure_count: int) -> str:
    return _iso_utc(_as_utc(now) + _dt.timedelta(seconds=_backoff_seconds(failure_count)))


def _row_values(
    key: PositionKey,
    target: str,
    attempt_at: str,
    result: FetchResult,
    existing: Optional[QuoteRow],
    now: _dt.datetime,
) -> tuple[Any, ...]:
    cached = (
        existing.close_price,
        existing.week_ending,
        existing.market_date,
        existing.fetched_at,
        existing.source,
    ) if existing else (None, None, None, None, None)
    if result.outcome == "ok":
        return (
            key.symbol,
            key.currency,
            canonical_decimal(result.close_price),
            target,
            result.market_date,
            _iso_utc(now),
            result.source or "yahoo_chart",
            "ok",
            target,
            attempt_at,
            None,
            0,
            None,
        )
    failure_count = 0
    if result.outcome == "transient_error":
        if existing and existing.target_week_ending == target and existing.fetch_outcome == "transient_error":
            failure_count = existing.failure_count
        failure_count += 1
    return (
        key.symbol,
        key.currency,
        *cached,
        result.outcome,
        target,
        attempt_at,
        result.error_code,
        failure_count,
        _retry_after(now, failure_count) if result.outcome == "transient_error" else None,
    )


def _held_key(con: sqlite3.Connection, key: PositionKey) -> bool:
    for quantity, in con.execute(
        "SELECT quantity FROM positions WHERE upper(trim(symbol))=? AND upper(trim(currency))=?",
        (key.symbol, key.currency),
    ):
        if _decimal_nonzero(quantity):
            return True
    return False


def _write_result(
    db_path: str,
    key: PositionKey,
    target: str,
    attempt_at: str,
    result: FetchResult,
    now: _dt.datetime,
) -> bool:
    """Commit one result after rechecking the held position and row ordering."""
    con = sqlite3.connect(db_path, timeout=30)
    con.execute("PRAGMA busy_timeout=5000")
    try:
        with con:
            if not _held_key(con, key):
                return False
            old_tuple = con.execute(
                "SELECT symbol,currency,close_price,week_ending,market_date,fetched_at,source,"
                "fetch_outcome,target_week_ending,last_attempt_at,last_error_code,failure_count,retry_after "
                "FROM position_quotes WHERE symbol=? AND currency=?",
                (key.symbol, key.currency),
            ).fetchone()
            existing = None
            if old_tuple:
                existing = QuoteRow(
                    old_tuple[0], old_tuple[1], old_tuple[2], old_tuple[3], old_tuple[4], old_tuple[5], old_tuple[6],
                    old_tuple[7], old_tuple[8], old_tuple[9], old_tuple[10], int(old_tuple[11]), old_tuple[12]
                )
                if existing.target_week_ending > target:
                    return False
                if existing.target_week_ending == target and existing.last_attempt_at > attempt_at:
                    return False
            values = _row_values(key, target, attempt_at, result, existing, now)
            existing_values = (
                existing.symbol,
                existing.currency,
                existing.close_price,
                existing.week_ending,
                existing.market_date,
                existing.fetched_at,
                existing.source,
                existing.fetch_outcome,
                existing.target_week_ending,
                existing.last_attempt_at,
                existing.last_error_code,
                existing.failure_count,
                existing.retry_after,
            ) if existing else None
            if existing and existing_values == values:
                return False
            con.execute(
                "INSERT INTO position_quotes (symbol,currency,close_price,week_ending,market_date,fetched_at,source,"
                "fetch_outcome,target_week_ending,last_attempt_at,last_error_code,failure_count,retry_after) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(symbol,currency) DO UPDATE SET close_price=excluded.close_price,week_ending=excluded.week_ending,"
                "market_date=excluded.market_date,fetched_at=excluded.fetched_at,source=excluded.source,"
                "fetch_outcome=excluded.fetch_outcome,target_week_ending=excluded.target_week_ending,"
                "last_attempt_at=excluded.last_attempt_at,last_error_code=excluded.last_error_code,"
                "failure_count=excluded.failure_count,retry_after=excluded.retry_after",
                values,
            )
            return True
    finally:
        con.close()


@contextmanager
def quote_lock(root: Optional[str] = None):
    """Acquire the quote-specific nonblocking run lock, yielding False when busy."""
    root = root or ROOT
    state = os.path.join(root, "state")
    os.makedirs(state, exist_ok=True)
    path = os.path.join(state, ".position_quotes.lock")
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    acquired = False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                raise
        yield acquired
    finally:
        if acquired:
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _db_path(root: str) -> str:
    try:
        import store

        if root == ROOT:
            return store.db_path()
    except Exception:
        pass
    return os.path.join(root, "state", "market.sqlite")


def _open_read(db_path: str, root: str) -> sqlite3.Connection:
    con = sqlite3.connect(db_path, timeout=30)
    con.execute("PRAGMA busy_timeout=5000")
    # The dispatcher may be the first process to touch a v5 store after the schema
    # amendment.  Use the canonical verified migration path before reading/writing quotes;
    # tests that already provide the v6 table avoid creating backups in the live tree.
    table = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='position_quotes' LIMIT 1"
    ).fetchone()
    if not table:
        import migrate

        old_root = migrate.ROOT
        migrate.ROOT = root
        try:
            migrate.ensure_schema(con, db_path)
        finally:
            migrate.ROOT = old_root
    return con


def run(
    db_path: Optional[str] = None,
    now: Optional[_dt.datetime] = None,
    opener: Optional[Any] = None,
    max_symbols: int = MAX_SYMBOLS_PER_RUN,
    root: Optional[str] = None,
) -> dict[str, Any]:
    """Run one bounded update and return a diagnostic summary.

    ``now`` and ``opener`` are injectable for deterministic calendar/network tests.  The
    production dispatcher calls this without either override.
    """
    root = root or ROOT
    db_path = db_path or _db_path(root)
    current_now = _as_ny(now)
    target, market_date = quote_target(current_now)
    with quote_lock(root) as acquired:
        if not acquired:
            return {"status": "lock_busy", "target_week_ending": target, "attempted": 0}
        if not os.path.isfile(db_path):
            return {"status": "unavailable", "target_week_ending": target, "attempted": 0, "error": "database_missing"}
        try:
            con = _open_read(db_path, root)
            try:
                positions = _current_positions(con)
                rows = _read_quote_rows(con)
            finally:
                con.close()
        except (OSError, sqlite3.Error) as exc:
            return {"status": "unavailable", "target_week_ending": target, "attempted": 0, "error": _bounded_error_code(exc)}

        # Deterministically classify local unsupported keys.  An unchanged unsupported row
        # is left byte-for-byte alone, so a 15-minute tick does not manufacture writes.
        for key in sorted(positions, key=lambda k: (k.symbol, k.currency)):
            reason = None
            request_symbol = None
            if key.currency != "USD":
                reason = "unsupported_currency"
            else:
                request_symbol = yahoo_symbol(key.symbol)
                if request_symbol is None:
                    reason = "invalid_symbol"
            if reason is None:
                continue
            old = rows.get(key)
            if old and old.target_week_ending == target and old.fetch_outcome == "unsupported" and old.last_error_code == reason:
                continue
            result = FetchResult("unsupported", error_code=reason)
            attempt_at = _iso_utc(current_now)
            if _write_result(db_path, key, target, attempt_at, result, current_now):
                rows[key] = QuoteRow(
                    key.symbol, key.currency, old.close_price if old else None, old.week_ending if old else None,
                    old.market_date if old else None, old.fetched_at if old else None, old.source if old else None,
                    "unsupported", target, attempt_at, reason, 0, None
                )

        candidates: list[tuple[tuple[int, str], PositionKey, QuoteRow | None, str]] = []
        for key in sorted(positions, key=lambda k: (k.symbol, k.currency)):
            if key.currency != "USD":
                continue
            request_symbol = yahoo_symbol(key.symbol)
            if request_symbol is None:
                continue
            old = rows.get(key)
            if old and old.target_week_ending == target and old.fetch_outcome == "ok":
                continue
            if old and old.target_week_ending == target and old.fetch_outcome == "unsupported":
                continue
            if old and not _retry_due(old, current_now, target):
                continue
            never_attempted_for_target = old is None or old.target_week_ending != target
            attempt_sort = old.last_attempt_at if old else ""
            candidates.append(((0 if never_attempted_for_target else 1, attempt_sort), key, old, request_symbol))
        candidates.sort(key=lambda item: (item[0], item[1].symbol, item[1].currency))

        attempted = 0
        committed = 0
        outcomes: dict[str, int] = {"ok": 0, "transient_error": 0, "unsupported": 0}
        for _, key, old, request_symbol in candidates[: max(0, int(max_symbols))]:
            attempted += 1
            try:
                result = fetch_quote(request_symbol, market_date, opener=opener)
            except QuoteError as exc:
                result = FetchResult("transient_error", error_code=exc.code)
            except Exception as exc:
                result = FetchResult("transient_error", error_code=_bounded_error_code(exc))
            outcomes[result.outcome] = outcomes.get(result.outcome, 0) + 1
            attempt_at = _iso_utc(current_now)
            if _write_result(db_path, key, target, attempt_at, result, current_now):
                committed += 1
        return {
            "status": "ok",
            "target_week_ending": target,
            "market_date": market_date,
            "attempted": attempted,
            "committed": committed,
            "outcomes": outcomes,
        }


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=None, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        summary = run(db_path=args.db)
        print(json.dumps(summary, sort_keys=True))
    except Exception as exc:
        # The dispatcher treats this probe as isolated; retain a useful quote-specific log
        # without changing the ingest/debrief/watchdog result.
        print(json.dumps({"status": "error", "error": _bounded_error_code(exc)}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
