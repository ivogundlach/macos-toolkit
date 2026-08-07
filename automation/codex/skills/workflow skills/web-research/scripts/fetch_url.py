#!/usr/bin/env python3
"""Fetch one public HTTP(S) URL into completion-marked hidden evidence."""

from __future__ import annotations

import argparse
import hashlib
import html.parser
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import tempfile
import unicodedata
import zlib
from pathlib import Path
from typing import Callable
from urllib.parse import SplitResult, urljoin, urlsplit, urlunsplit


USER_AGENT = "IvoWebResearch/1.0 (single-page research fetch)"
REDIRECT_STATUSES = {301, 302, 303, 307, 308}
TEXT_TYPES = ("text/", "application/json", "application/xml", "application/xhtml+xml")
BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "br", "div", "dl", "dt", "dd",
    "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
    "main", "nav", "ol", "p", "pre", "section", "table", "td", "th", "tr", "ul",
}
SKIP_TAGS = {"script", "style", "noscript", "svg", "template"}


class FetchError(RuntimeError):
    pass


class BodyTooLarge(FetchError):
    pass


class PinnedHTTPConnection(http.client.HTTPConnection):
    """Dial a validated IP while retaining the original HTTP hostname."""

    def __init__(self, host: str, port: int, pinned_ip: str, timeout: float):
        super().__init__(host, port=port, timeout=timeout)
        self.pinned_ip = pinned_ip

    def connect(self) -> None:
        self.sock = socket.create_connection(
            (self.pinned_ip, self.port), self.timeout, self.source_address
        )


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """Dial a validated IP while validating TLS for the original hostname."""

    def __init__(
        self,
        host: str,
        port: int,
        pinned_ip: str,
        timeout: float,
        context: ssl.SSLContext | None = None,
    ):
        super().__init__(host, port=port, timeout=timeout, context=context)
        self.pinned_ip = pinned_ip

    def connect(self) -> None:
        raw = socket.create_connection(
            (self.pinned_ip, self.port), self.timeout, self.source_address
        )
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


def ip_is_public(value: str) -> bool:
    address = ipaddress.ip_address(value)
    return bool(
        address.is_global
        and not address.is_private
        and not address.is_loopback
        and not address.is_link_local
        and not address.is_reserved
        and not address.is_multicast
        and not address.is_unspecified
    )


def parse_public_url(url: str) -> SplitResult:
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"}:
        raise FetchError("only public http:// and https:// URLs are allowed")
    if not parsed.hostname:
        raise FetchError("URL has no hostname")
    if parsed.username or parsed.password:
        raise FetchError("credentials in URLs are not allowed")
    try:
        _ = parsed.port
    except ValueError as error:
        raise FetchError(f"invalid URL port: {error}") from error
    return parsed


def resolve_public(
    host: str,
    port: int,
    resolver: Callable[..., list] = socket.getaddrinfo,
) -> str:
    try:
        records = resolver(host, port, type=socket.SOCK_STREAM)
    except OSError as error:
        raise FetchError(f"DNS resolution failed for {host}: {error}") from error
    addresses = sorted({record[4][0] for record in records})
    if not addresses:
        raise FetchError(f"DNS returned no addresses for {host}")
    rejected = [address for address in addresses if not ip_is_public(address)]
    if rejected:
        raise FetchError(f"DNS returned a non-public address for {host}: {rejected}")
    return addresses[0]


def request_target(parsed: SplitResult) -> str:
    path = parsed.path or "/"
    return f"{path}?{parsed.query}" if parsed.query else path


def read_bounded(response: http.client.HTTPResponse, max_bytes: int) -> tuple[bytes, int, bool, str]:
    encoding = (response.getheader("Content-Encoding") or "identity").lower().strip()
    supported = encoding in {"", "identity", "gzip", "x-gzip"}
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS) if encoding in {"gzip", "x-gzip"} else None
    wire_count = 0
    output = bytearray()
    truncated = False

    while True:
        remaining_wire = max_bytes - min(wire_count, max_bytes)
        chunk = response.read(min(65536, remaining_wire + 1))
        if not chunk:
            break
        wire_count += len(chunk)
        wire_overflow = wire_count > max_bytes
        if wire_overflow:
            chunk = chunk[:remaining_wire]
        if not supported:
            decoded = chunk
        elif decompressor is not None:
            decoded = decompressor.decompress(chunk, max_bytes - len(output) + 1)
        else:
            decoded = chunk
        output.extend(decoded)
        if len(output) > max_bytes:
            del output[max_bytes:]
            truncated = True
            break
        if wire_overflow:
            truncated = True
            break

    if not truncated and decompressor is not None:
        tail = decompressor.flush(max_bytes - len(output) + 1)
        output.extend(tail)
        if len(output) > max_bytes:
            del output[max_bytes:]
            truncated = True
    return bytes(output), wire_count, truncated, encoding or "identity"


class TextExtractor(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in SKIP_TAGS:
            self.skip_depth += 1
        elif not self.skip_depth and tag in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in SKIP_TAGS and self.skip_depth:
            self.skip_depth -= 1
        elif not self.skip_depth and tag in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self.skip_depth:
            self.parts.append(data)

    def text(self) -> str:
        lines = []
        for line in "".join(self.parts).splitlines():
            clean = re.sub(r"\s+", " ", line).strip()
            if clean:
                lines.append(clean)
        return "\n".join(lines) + ("\n" if lines else "")


def choose_charset(content_type: str, body: bytes) -> tuple[str, str | None]:
    header = re.search(r"charset\s*=\s*['\"]?([^;'\"\s]+)", content_type, re.I)
    sample = body[:8192].decode("ascii", errors="ignore")
    meta = re.search(r"<meta[^>]+charset\s*=\s*['\"]?([^'\"\s/>]+)", sample, re.I)
    candidates = [match.group(1) for match in (header, meta) if match]
    candidates.extend(["utf-8", "windows-1252"])
    for candidate in candidates:
        try:
            return body.decode(candidate), candidate
        except (LookupError, UnicodeDecodeError):
            continue
    return body.decode("utf-8", errors="replace"), None


def extract_text(content_type: str, encoding: str, body: bytes) -> tuple[str | None, str | None]:
    if encoding not in {"identity", "gzip", "x-gzip"}:
        return None, None
    media_type = content_type.split(";", 1)[0].strip().lower()
    if not (media_type.startswith(TEXT_TYPES) or media_type in {"", "application/javascript"}):
        return None, None
    decoded, charset = choose_charset(content_type, body)
    if "html" in media_type or "<html" in decoded[:1000].lower():
        parser = TextExtractor()
        parser.feed(decoded)
        return parser.text(), charset
    return decoded, charset


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
        temporary = Path(handle.name)
    temporary.replace(path)


def contained(path: Path, base: Path) -> bool:
    resolved = unicodedata.normalize(
        "NFC", str(path.expanduser().resolve(strict=False))
    ).casefold()
    root = unicodedata.normalize(
        "NFC", str(base.expanduser().resolve(strict=False))
    ).casefold()
    try:
        return os.path.commonpath([root, resolved]) == root
    except ValueError:
        return False


def visible_match(path: Path) -> Path | None:
    for root in (Path.home() / "Downloads", Path.home() / "Files"):
        if contained(path, root):
            return root
    return None


def fetch(
    url: str,
    output_dir: Path,
    accept: str,
    max_bytes: int,
    timeout: float,
    max_redirects: int,
    resolver: Callable[..., list] = socket.getaddrinfo,
) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "complete.json").unlink(missing_ok=True)
    current = url
    chain: list[dict] = []
    final_body = b""
    final_headers: dict[str, str] = {}
    final_status = 0
    wire_bytes = 0
    truncated = False
    content_encoding = "identity"

    for hop in range(max_redirects + 1):
        parsed = parse_public_url(current)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        pinned_ip = resolve_public(parsed.hostname or "", port, resolver)
        connection: http.client.HTTPConnection
        if parsed.scheme == "https":
            connection = PinnedHTTPSConnection(parsed.hostname or "", port, pinned_ip, timeout)
        else:
            connection = PinnedHTTPConnection(parsed.hostname or "", port, pinned_ip, timeout)
        headers = {
            "Accept": accept,
            "Accept-Encoding": "gzip",
            "Connection": "close",
            "User-Agent": USER_AGENT,
        }
        try:
            connection.request("GET", request_target(parsed), headers=headers)
            response = connection.getresponse()
            status = response.status
            response_headers = {key.lower(): value for key, value in response.getheaders()}
            location = response_headers.get("location")
            chain.append(
                {
                    "url": urlunsplit(parsed._replace(fragment="")),
                    "status": status,
                    "location": location,
                    "resolved_ip": pinned_ip,
                }
            )
            if status in REDIRECT_STATUSES and location:
                response.read(0)
                if hop == max_redirects:
                    raise FetchError(f"redirect limit exceeded ({max_redirects})")
                current = urljoin(current, location)
                continue
            final_body, wire_bytes, truncated, content_encoding = read_bounded(response, max_bytes)
            final_headers = response_headers
            final_status = status
            break
        finally:
            connection.close()
    else:
        raise FetchError("no final response")

    content_type = final_headers.get("content-type", "")
    text, charset = extract_text(content_type, content_encoding, final_body)
    text_length = len(text.strip()) if text is not None else 0
    likely_shell = bool(
        "html" in content_type.lower()
        and len(final_body) > 1000
        and text_length < 200
        and re.search(rb"id=[\"'](?:root|app|__next)[\"']|loading", final_body, re.I)
    )
    anomalies = []
    if content_encoding not in {"identity", "gzip", "x-gzip"}:
        anomalies.append(f"unsupported content-encoding: {content_encoding}")
    if truncated:
        anomalies.append(f"body exceeded decoded/wire limit of {max_bytes} bytes")
    if text is None:
        anomalies.append("response was not safely text-extractable; inspect body.raw or escalate")
    if likely_shell:
        anomalies.append("likely client-rendered shell; render once before treating as content")

    metadata = {
        "original_url": url,
        "final_url": chain[-1]["url"],
        "status": final_status,
        "content_type": content_type,
        "content_encoding": content_encoding,
        "charset": charset,
        "redirect_chain": chain,
        "body_bytes": len(final_body),
        "wire_bytes": wire_bytes,
        "body_sha256": hashlib.sha256(final_body).hexdigest(),
        "truncated": truncated,
        "likely_client_rendered_shell": likely_shell,
        "text_extracted": text is not None,
        "anomalies": anomalies,
        "robots_policy": "single requested page; no automatic robots.txt fetch or crawling",
    }
    atomic_write(output_dir / "body.raw", final_body)
    if text is not None:
        atomic_write(output_dir / "text.txt", text.encode("utf-8"))
    else:
        (output_dir / "text.txt").unlink(missing_ok=True)
    encoded_metadata = (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write(output_dir / "metadata.json", encoded_metadata)
    atomic_write(output_dir / "complete.json", encoded_metadata)
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--accept", default="text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.5")
    parser.add_argument("--max-bytes", type=int, default=10_000_000)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--max-redirects", type=int, default=8)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    if args.max_bytes < 1 or args.max_redirects < 0 or args.timeout <= 0:
        parser.error("limits and timeout must be positive")
    if args.output_dir:
        output_dir = args.output_dir.expanduser().resolve()
        matched = visible_match(output_dir)
        if matched is not None:
            parser.error(
                f"web evidence is backend state; output matched visible guard {matched}"
            )
    else:
        root = Path.home() / ".local/state/web-research/fetches"
        root.mkdir(parents=True, exist_ok=True)
        prefix = hashlib.sha256(args.url.encode("utf-8")).hexdigest()[:12] + "-"
        output_dir = Path(tempfile.mkdtemp(prefix=prefix, dir=root))
    try:
        metadata = fetch(
            args.url,
            output_dir,
            args.accept,
            args.max_bytes,
            args.timeout,
            args.max_redirects,
        )
    except (FetchError, OSError, http.client.HTTPException, ssl.SSLError, zlib.error) as error:
        print(f"fetch_url failed: {error}", file=os.sys.stderr)
        return 1
    print(json.dumps({"output_dir": str(output_dir), **metadata}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
