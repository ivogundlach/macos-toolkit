#!/usr/bin/python3
"""Open the GWS OAuth URL while leaving credentials and consent to the user."""

from __future__ import annotations

import argparse
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit


SCOPES = (
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/spreadsheets.readonly",
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/documents.readonly",
    "https://www.googleapis.com/auth/tasks.readonly",
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/directory.readonly",
)
SERVICE_NAMES = "Drive, Sheets, Gmail, Calendar, Docs, Tasks, Contacts, and Directory"
URL_PATTERN = re.compile(r"https://[^\s\x1b]+")


class LoginInterrupted(Exception):
    pass


def google_oauth_url(text: str) -> tuple[str | None, bool]:
    """Return an allowed Google OAuth URL and whether any rejected URL appeared."""
    rejected = False
    for raw in URL_PATTERN.findall(text):
        candidate = raw.rstrip(".,;)]}>\"'")
        parsed = urlsplit(candidate)
        if (
            parsed.scheme == "https"
            and parsed.hostname == "accounts.google.com"
            and parsed.path.startswith("/o/oauth2/")
        ):
            return candidate, rejected
        rejected = True
    return None, rejected


def terminate_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def open_browser(open_bin: str, url: str) -> bool:
    try:
        result = subprocess.run(
            [open_bin, url],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"\nCould not open the browser: {exc}", file=sys.stderr, flush=True)
        return False
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        print(f"\nCould not open the browser: {detail}", file=sys.stderr, flush=True)
        return False
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gws-bin", required=True)
    parser.add_argument("--open-bin", default="/usr/bin/open")
    parser.add_argument("--url-timeout", type=float, default=60.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    gws = Path(args.gws_bin)
    if not gws.is_file() or not os.access(gws, os.X_OK):
        print(f"GWS executable is unavailable: {gws}", file=sys.stderr)
        return 127
    if args.url_timeout <= 0:
        print("URL timeout must be positive.", file=sys.stderr)
        return 2

    print("— Log in to Google —", flush=True)
    print(f"Requesting your previously configured read-only access: {SERVICE_NAMES}.", flush=True)
    print("Google will show the final permissions before anything is granted.\n", flush=True)

    command = [str(gws), "auth", "login", "--scopes", ",".join(SCOPES)]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    assert process.stdout is not None

    def interrupted(_signum: int, _frame: object) -> None:
        raise LoginInterrupted

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    captured = bytearray()
    oauth_url: str | None = None
    rejected_url = False
    opened = False
    started = time.monotonic()

    try:
        while oauth_url is None and process.poll() is None:
            if time.monotonic() - started >= args.url_timeout:
                print(
                    "\nGWS did not provide a Google sign-in URL within "
                    f"{args.url_timeout:g} seconds. Its output is shown above.",
                    file=sys.stderr,
                    flush=True,
                )
                terminate_group(process)
                return 124
            for key, _mask in selector.select(timeout=0.2):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(process.stdout)
                    break
                os.write(sys.stdout.fileno(), chunk)
                captured.extend(chunk)
                if len(captured) > 262144:
                    del captured[:-131072]
                oauth_url, saw_rejected = google_oauth_url(
                    captured.decode("utf-8", errors="replace")
                )
                rejected_url = rejected_url or saw_rejected

        if oauth_url is not None:
            opened = open_browser(args.open_bin, oauth_url)
            if opened:
                print(
                    "\nOpened Google sign-in in your default browser. "
                    "Finish there; this window will close after Google returns.",
                    flush=True,
                )
            else:
                print(
                    "\nOpen this URL manually to continue:\n\n"
                    f"  {oauth_url}\n",
                    file=sys.stderr,
                    flush=True,
                )

        while process.poll() is None:
            for key, _mask in selector.select(timeout=0.5):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    try:
                        selector.unregister(process.stdout)
                    except KeyError:
                        pass
                    break
                os.write(sys.stdout.fileno(), chunk)

        remainder = process.stdout.read()
        if remainder:
            os.write(sys.stdout.fileno(), remainder)
        returncode = process.wait()

        if oauth_url is None:
            if returncode == 0:
                print(
                    "\nGWS completed without requiring browser authentication.",
                    flush=True,
                )
                return 0
            if rejected_url:
                print(
                    "\nGWS emitted a URL outside the allowed Google OAuth endpoint; "
                    "the browser was not opened.",
                    file=sys.stderr,
                    flush=True,
                )
            print(
                f"\nGWS exited before providing a Google sign-in URL (exit {returncode}).",
                file=sys.stderr,
                flush=True,
            )
            return returncode

        if returncode == 0:
            print("\nGoogle Workspace login completed.", flush=True)
        elif opened:
            print(
                f"\nGoogle Workspace login did not complete (exit {returncode}).",
                file=sys.stderr,
                flush=True,
            )
        return returncode
    except (KeyboardInterrupt, LoginInterrupted):
        terminate_group(process)
        print(
            "\nGoogle login was interrupted. Credentials changed only if Google "
            "had already completed the callback.",
            file=sys.stderr,
            flush=True,
        )
        return 130
    finally:
        selector.close()


if __name__ == "__main__":
    raise SystemExit(main())
