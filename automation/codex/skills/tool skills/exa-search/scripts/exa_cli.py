#!/usr/bin/env python3
"""Direct, dependency-free Exa Search and Contents CLI."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


API_BASE = "https://api.exa.ai"
KEYCHAIN_SERVICES = ("exa-EXA_API_KEY", "last30days-EXA_API_KEY")
TRANSIENT_HTTP = {408, 429, 500, 502, 503, 504}
DEFAULT_TIMEOUT = 20.0
DEFAULT_MAX_BYTES = 20_000_000
DEFAULT_ATTEMPTS = 2

EXIT_USAGE = 2
EXIT_AUTH = 3
EXIT_NETWORK = 4
EXIT_API = 5
EXIT_DATA = 6


class ExaError(RuntimeError):
    def __init__(self, kind: str, message: str, repair: str, exit_code: int):
        super().__init__(message)
        self.kind = kind
        self.message = message
        self.repair = repair
        self.exit_code = exit_code


def _keychain_value(service: str) -> str | None:
    if sys.platform != "darwin" or os.environ.get("EXA_DISABLE_KEYCHAIN") == "1":
        return None
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-a", os.environ.get("USER", ""),
             "-s", service, "-w"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def credential() -> tuple[str | None, str, list[str]]:
    env_key = os.environ.get("EXA_API_KEY", "").strip()
    keychain: list[tuple[str, str]] = []
    for service in KEYCHAIN_SERVICES:
        value = _keychain_value(service)
        if value:
            keychain.append((service, value))
    warnings: list[str] = []
    if env_key:
        if any(value != env_key for _, value in keychain):
            warnings.append("EXA_API_KEY differs from Keychain; environment value wins")
        return env_key, "environment", warnings
    if keychain:
        service, value = keychain[0]
        if any(other != value for _, other in keychain[1:]):
            warnings.append(f"multiple Exa Keychain values differ; {service} wins")
        return value, f"keychain:{service}", warnings
    return None, "missing", warnings


def _redact(value: str, key: str | None) -> str:
    if key:
        value = value.replace(key, "[REDACTED]")
    return re.sub(r"(?i)(x-api-key|authorization)\s*[:=]\s*[^\s,;]+", r"\1=[REDACTED]", value)


def _repair_for_http(status: int) -> str:
    if status in {401, 403}:
        return "Run `exa-search status`; replace EXA_API_KEY or run `exa-search auth-store` with a valid environment key."
    if status == 402:
        return "Check Exa billing or credits, then retry the same command."
    if status == 429:
        return "Wait for the Exa rate limit to reset or reduce request frequency, then retry."
    if status >= 500:
        return "Retry later; if Exa remains unavailable, disclose the outage before using another discovery path."
    return "Inspect the request arguments against current Exa API documentation and retry."


def api_request(
    endpoint: str,
    payload: dict[str, Any],
    key: str,
    *,
    timeout: float,
    max_bytes: int,
    attempts: int,
    api_base: str = API_BASE,
) -> tuple[dict[str, Any], int]:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        f"{api_base.rstrip('/')}/{endpoint.lstrip('/')}",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "IvoExaSearch/1.0",
            "x-api-key": key,
        },
    )
    last_error: ExaError | None = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read(max_bytes + 1)
                if len(raw) > max_bytes:
                    raise ExaError(
                        "response_too_large",
                        f"Exa response exceeded {max_bytes} bytes",
                        "Reduce result count, subpages, or requested text size and retry.",
                        EXIT_DATA,
                    )
                try:
                    parsed = json.loads(raw)
                except json.JSONDecodeError as error:
                    raise ExaError(
                        "invalid_json",
                        f"Exa returned invalid JSON: {error}",
                        "Retry once; if it repeats, report the Exa response-format failure.",
                        EXIT_DATA,
                    ) from error
                if not isinstance(parsed, dict):
                    raise ExaError(
                        "invalid_response",
                        "Exa response root was not an object",
                        "Retry once; if it repeats, report an Exa API compatibility failure.",
                        EXIT_DATA,
                    )
                return parsed, attempt
        except urllib.error.HTTPError as error:
            raw = error.read(64_000)
            detail = raw.decode("utf-8", errors="replace")
            message = _redact(f"Exa HTTP {error.code}: {detail[:2000]}", key)
            last_error = ExaError(
                "http_error", message, _repair_for_http(error.code),
                EXIT_AUTH if error.code in {401, 403} else EXIT_API,
            )
            if error.code not in TRANSIENT_HTTP or attempt == attempts:
                raise last_error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = ExaError(
                "network_error",
                _redact(f"Exa request failed: {error}", key),
                "Check network and DNS access to api.exa.ai, then retry the same command.",
                EXIT_NETWORK,
            )
            if attempt == attempts:
                raise last_error
        if attempt < attempts:
            time.sleep(min(1.5, 0.4 * (2 ** (attempt - 1))))
    assert last_error is not None
    raise last_error


def validate_public_url(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise argparse.ArgumentTypeError("URL must use public http:// or https://")
    if parsed.username or parsed.password:
        raise argparse.ArgumentTypeError("credentials in URLs are not allowed")
    return value


def emit(data: dict[str, Any], output: Path | None) -> None:
    encoded = json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    if output:
        resolved = output.expanduser().resolve()
        for visible in (Path.home() / "Downloads", Path.home() / "Files"):
            try:
                resolved.relative_to(visible.resolve())
            except ValueError:
                continue
            raise ExaError(
                "visible_output_rejected",
                f"raw Exa output cannot be written under {visible}",
                "Use hidden research state such as ~/.local/state/web-research/.",
                EXIT_USAGE,
            )
        resolved.parent.mkdir(parents=True, exist_ok=True)
        temporary = resolved.with_name(resolved.name + ".tmp")
        temporary.write_text(encoded, encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(resolved)
    else:
        sys.stdout.write(encoded)


def require_key() -> tuple[str, str, list[str]]:
    key, source, warnings = credential()
    if not key:
        raise ExaError(
            "missing_credentials",
            "EXA_API_KEY is not available in the environment or supported Keychain services",
            "Export EXA_API_KEY, verify with `exa-search status --live`, then optionally persist it with `exa-search auth-store`.",
            EXIT_AUTH,
        )
    return key, source, warnings


def command_status(args: argparse.Namespace) -> dict[str, Any]:
    key, source, warnings = credential()
    result: dict[str, Any] = {
        "ok": bool(key),
        "credential_source": source,
        "warnings": warnings,
        "live_checked": False,
    }
    if not key:
        result["repair"] = "Export EXA_API_KEY, then run `exa-search status --live`."
        return result
    if args.live:
        response, attempts_used = api_request(
            "search",
            {"query": "Exa API connectivity check", "type": "fast", "numResults": 1},
            key,
            timeout=args.timeout,
            max_bytes=args.max_bytes,
            attempts=args.attempts,
        )
        result.update({
            "live_checked": True,
            "attempts_used": attempts_used,
            "request_id": response.get("requestId"),
            "result_count": len(response.get("results") or []),
        })
    return result


def command_search(args: argparse.Namespace) -> dict[str, Any]:
    key, source, warnings = require_key()
    payload: dict[str, Any] = {
        "query": args.query,
        "type": args.search_type,
        "numResults": args.num_results,
    }
    if args.category:
        payload["category"] = args.category
    if args.include_domain:
        payload["includeDomains"] = args.include_domain
    if args.exclude_domain:
        payload["excludeDomains"] = args.exclude_domain
    if args.start_published:
        payload["startPublishedDate"] = args.start_published
    if args.end_published:
        payload["endPublishedDate"] = args.end_published
    contents: dict[str, Any] = {}
    if args.content in {"highlights", "both"}:
        contents["highlights"] = {"maxCharacters": args.max_characters}
    if args.content in {"text", "both"}:
        contents["text"] = {"maxCharacters": args.max_characters}
    if args.fresh:
        contents["maxAgeHours"] = 0
    if contents:
        payload["contents"] = contents
    response, attempts_used = api_request(
        "search", payload, key, timeout=args.timeout, max_bytes=args.max_bytes,
        attempts=args.attempts,
    )
    if not (response.get("results") or []):
        raise ExaError(
            "no_results",
            "Exa completed the search but returned no results",
            "Broaden or rephrase the query; if coverage still matters, disclose the empty Exa path before using another search engine.",
            EXIT_DATA,
        )
    return {
        "ok": True,
        "operation": "search",
        "credential_source": source,
        "warnings": warnings,
        "attempts_used": attempts_used,
        "request": {"query": args.query, "type": args.search_type, "num_results": args.num_results},
        "response": response,
    }


def command_contents(args: argparse.Namespace) -> dict[str, Any]:
    key, source, warnings = require_key()
    payload: dict[str, Any] = {"urls": args.urls}
    if args.mode in {"text", "both"}:
        payload["text"] = {"maxCharacters": args.max_characters}
    if args.mode in {"highlights", "both"}:
        payload["highlights"] = (
            {"query": args.highlights_query, "maxCharacters": args.max_characters}
            if args.highlights_query else True
        )
    if args.fresh:
        payload["maxAgeHours"] = 0
    if args.subpages:
        payload["subpages"] = args.subpages
    if args.subpage_target:
        payload["subpageTarget"] = args.subpage_target
    response, attempts_used = api_request(
        "contents", payload, key, timeout=args.timeout, max_bytes=args.max_bytes,
        attempts=args.attempts,
    )
    results = response.get("results") or []
    statuses = response.get("statuses") or []
    failed_statuses = [
        item for item in statuses
        if isinstance(item, dict) and str(item.get("status", "")).lower() not in {"success", "cached"}
    ]
    if failed_statuses:
        raise ExaError(
            "partial_content_failure",
            f"Exa failed one or more requested URLs: {json.dumps(failed_statuses)[:1500]}",
            "Retry the failed URLs individually; disclose unresolved URLs before substituting another acquisition path.",
            EXIT_DATA,
        )
    if not results:
        raise ExaError(
            "no_content",
            f"Exa returned no content results; statuses={json.dumps(statuses)[:1500]}",
            "Inspect the URL for access controls or retry with `--fresh`; use Firecrawl or a browser only after reporting this path failure.",
            EXIT_DATA,
        )
    return {
        "ok": True,
        "operation": "contents",
        "credential_source": source,
        "warnings": warnings,
        "attempts_used": attempts_used,
        "request": {"urls": args.urls, "mode": args.mode},
        "response": response,
    }


def command_auth_store(_: argparse.Namespace) -> dict[str, Any]:
    key = os.environ.get("EXA_API_KEY", "").strip()
    if not key:
        raise ExaError(
            "missing_environment_key",
            "auth-store requires EXA_API_KEY in the current environment",
            "Export a valid EXA_API_KEY and run `exa-search status --live` before storing it.",
            EXIT_AUTH,
        )
    if sys.platform != "darwin":
        raise ExaError("unsupported_platform", "auth-store requires macOS Keychain", "Use EXA_API_KEY in the environment.", EXIT_USAGE)
    # `security add-generic-password -w` does NOT read the password from stdin.
    # Piping it exits 0 and stores an EMPTY password, so the write has to pass
    # the value as an argument. The brief argv exposure is the only way the tool
    # supports a non-interactive write.
    result = subprocess.run(
        ["security", "add-generic-password", "-U", "-a", os.environ.get("USER", ""),
         "-s", KEYCHAIN_SERVICES[0], "-w", key],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    if result.returncode != 0:
        raise ExaError(
            "keychain_write_failed",
            _redact(result.stderr.strip() or "macOS Keychain write failed", key),
            "Unlock the login Keychain and rerun `exa-search auth-store`.",
            EXIT_AUTH,
        )
    # Read back before claiming success. A write that stores the wrong value
    # still exits 0, and the failure would only surface later as a "missing"
    # credential with no indication that auth-store was the cause.
    if _keychain_value(KEYCHAIN_SERVICES[0]) != key:
        raise ExaError(
            "keychain_verify_failed",
            "Keychain reported a successful write but the stored value does not match",
            "Store it manually: security add-generic-password -U -a \"$USER\" "
            f"-s {KEYCHAIN_SERVICES[0]} -w '<key>'",
            EXIT_AUTH,
        )
    return {"ok": True, "operation": "auth-store", "service": KEYCHAIN_SERVICES[0], "verified": True}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--attempts", type=int, default=DEFAULT_ATTEMPTS)
    parser.add_argument("--output", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status", help="check credentials and optional live connectivity")
    status.add_argument("--live", action="store_true")
    status.set_defaults(handler=command_status)

    search = sub.add_parser("search", help="search the web")
    search.add_argument("query")
    search.add_argument("--type", dest="search_type", choices=("auto", "instant", "fast", "deep-lite", "deep", "deep-reasoning"), default="auto")
    search.add_argument("--num-results", type=int, default=8)
    search.add_argument("--content", choices=("highlights", "text", "both", "none"), default="highlights")
    search.add_argument("--max-characters", type=int, default=4000)
    search.add_argument("--fresh", action="store_true")
    search.add_argument("--category")
    search.add_argument("--include-domain", action="append", default=[])
    search.add_argument("--exclude-domain", action="append", default=[])
    search.add_argument("--start-published")
    search.add_argument("--end-published")
    search.set_defaults(handler=command_search)

    contents = sub.add_parser("contents", help="extract known public URLs")
    contents.add_argument("urls", nargs="+", type=validate_public_url)
    contents.add_argument("--mode", choices=("text", "highlights", "both"), default="text")
    contents.add_argument("--highlights-query")
    contents.add_argument("--max-characters", type=int, default=20_000)
    contents.add_argument("--fresh", action="store_true")
    contents.add_argument("--subpages", type=int, default=0)
    contents.add_argument("--subpage-target", action="append", default=[])
    contents.set_defaults(handler=command_contents)

    auth = sub.add_parser("auth-store", help="explicitly store the environment key in macOS Keychain")
    auth.set_defaults(handler=command_auth_store)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.timeout <= 0 or args.max_bytes < 1024 or not 1 <= args.attempts <= 3:
        parser.error("timeout must be positive, max-bytes >= 1024, and attempts between 1 and 3")
    if getattr(args, "num_results", 1) not in range(1, 101):
        parser.error("num-results must be between 1 and 100")
    if getattr(args, "max_characters", 1) < 1 or getattr(args, "subpages", 0) < 0:
        parser.error("max-characters must be positive and subpages non-negative")
    try:
        result = args.handler(args)
        emit(result, args.output)
        return 0 if result.get("ok", False) else EXIT_AUTH
    except ExaError as error:
        payload = {"ok": False, "kind": error.kind, "message": error.message, "repair": error.repair}
        sys.stderr.write(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
        return error.exit_code
    except KeyboardInterrupt:
        sys.stderr.write(json.dumps({"ok": False, "kind": "interrupted", "message": "Exa request interrupted", "repair": "Retry when ready."}) + "\n")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
