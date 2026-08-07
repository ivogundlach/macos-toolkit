"""Shared pipeline utilities: locking, atomic writes, logging, URL allowlist."""
import fcntl
import json
import os
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlsplit

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK_PATH = os.path.join(ROOT, "state", ".run.lock")


class RunLock:
    """OS advisory lock; metadata is informational, flock is authoritative (no stale-file problem)."""

    def __init__(self, name="pipeline"):
        self.name = name
        self.fh = None

    def __enter__(self):
        os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
        self.fh = open(LOCK_PATH, "w")
        try:
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(f"another run holds {LOCK_PATH}; aborting")
        self.fh.write(json.dumps({"pid": os.getpid(), "name": self.name,
                                  "started": datetime.now(timezone.utc).isoformat()}))
        self.fh.flush()
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


def atomic_write(path: str, data: str):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def log(adapter: str, msg: str):
    line = f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} [{adapter}] {msg}"
    print(line, file=sys.stderr)
    day = time.strftime("%Y-%m-%d")
    path = os.path.join(ROOT, "out", "logs", f"{day}.log")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def allowed_url(url: str, hosts) -> bool:
    try:
        p = urlsplit(url)
    except ValueError:
        return False
    if p.scheme != "https" or p.username or p.password or not p.hostname:
        return False
    return p.hostname.lower().rstrip(".") in hosts
