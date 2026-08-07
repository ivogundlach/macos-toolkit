#!/usr/bin/env python3
"""Verify that explicitly requested files persist in one saved Apple Mail draft."""

from __future__ import annotations

import argparse
import email
import email.policy
import hashlib
import json
import subprocess
import sys
import time
import unicodedata
from pathlib import Path


ROW_READER = "/Users/YOUR_USERNAME/.local/bin/apple-mail-rowid-body"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_read(path: Path, timeout: float = 10.0) -> bytes:
    deadline = time.monotonic() + timeout
    previous: tuple[int, int, str] | None = None
    while time.monotonic() < deadline:
        data = path.read_bytes()
        stat = path.stat()
        current = (stat.st_size, stat.st_mtime_ns, digest(data))
        if current == previous:
            return data
        previous = current
        time.sleep(0.5)
    raise RuntimeError("draft EMLX did not stabilize")


def emlx_message(data: bytes) -> email.message.EmailMessage:
    first_newline = data.find(b"\n")
    if first_newline < 0:
        raise RuntimeError("invalid EMLX length header")
    try:
        message_length = int(data[:first_newline].strip())
    except ValueError as exc:
        raise RuntimeError("invalid EMLX message length") from exc
    raw_message = data[first_newline + 1:first_newline + 1 + message_length]
    parsed = email.message_from_bytes(raw_message, policy=email.policy.default)
    if not isinstance(parsed, email.message.EmailMessage):
        raise RuntimeError("unexpected parsed message type")
    return parsed


def normalized(value: str) -> str:
    return unicodedata.normalize("NFC", value)


def addresses(value: str) -> set[str]:
    return {address.casefold() for _name, address in email.utils.getaddresses([value]) if address}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rowid", required=True, type=int)
    parser.add_argument("--expect", required=True, action="append")
    parser.add_argument("--from-address", required=True)
    parser.add_argument("--to-address", required=True, action="append")
    parser.add_argument("--subject", required=True)
    args = parser.parse_args()

    result = subprocess.run(
        [ROW_READER, "--json", str(args.rowid)],
        check=True,
        capture_output=True,
        text=True,
    )
    records = json.loads(result.stdout)
    if len(records) != 1:
        raise RuntimeError("draft row did not resolve uniquely")
    record = records[0]
    if "/Drafts" not in str(record.get("mailbox", "")):
        raise RuntimeError("resolved message is not in Drafts")
    emlx_path = Path(record["emlx"]).resolve(strict=True)
    message = emlx_message(stable_read(emlx_path))

    if addresses(message.get("From", "")) != {args.from_address.casefold()}:
        raise RuntimeError("persisted draft From mismatch")
    if addresses(message.get("To", "")) != {value.casefold() for value in args.to_address}:
        raise RuntimeError("persisted draft To mismatch")
    if str(message.get("Subject", "")) != args.subject:
        raise RuntimeError("persisted draft Subject mismatch")

    expected: dict[str, tuple[int, str]] = {}
    for raw_path in args.expect:
        path = Path(raw_path).expanduser().resolve(strict=True)
        data = path.read_bytes()
        expected[normalized(path.name)] = (len(data), digest(data))

    found: dict[str, tuple[int, str]] = {}
    found_details: dict[str, dict[str, str]] = {}
    for part in message.walk():
        filename = part.get_filename()
        if not filename:
            continue
        payload = part.get_payload(decode=True)
        if payload is None:
            continue
        name = normalized(filename)
        found[name] = (len(payload), digest(payload))
        found_details[name] = {
            "content_type": part.get_content_type(),
            "content_disposition": part.get_content_disposition() or "unspecified",
        }

    attachment_root = emlx_path.parent.parent / "Attachments" / str(args.rowid)
    if attachment_root.is_dir():
        for path in attachment_root.rglob("*"):
            if path.is_file():
                data = path.read_bytes()
                name = normalized(path.name)
                found.setdefault(name, (len(data), digest(data)))
                found_details.setdefault(
                    name,
                    {"content_type": "filesystem-only", "content_disposition": "filesystem-only"},
                )

    missing = [name for name, signature in expected.items() if found.get(name) != signature]
    placeholder_only = "Apple-string-attachment" in message.as_string() and not found
    output = {
        "status": "verified" if not missing else "not-verified",
        "rowid": args.rowid,
        "emlx": str(emlx_path),
        "expected": sorted(expected),
        "found": sorted(found),
        "found_details": {name: found_details[name] for name in sorted(found_details)},
        "missing": missing,
        "placeholder_only": placeholder_only,
    }
    print(json.dumps(output, ensure_ascii=False))
    return 0 if not missing else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(json.dumps({"status": "error", "error": str(exc)}), file=sys.stderr)
        raise SystemExit(2)
