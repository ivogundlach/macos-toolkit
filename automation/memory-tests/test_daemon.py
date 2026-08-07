#!/usr/bin/env python3
"""Behavioural tests for the daemon fail-open contract.

These assert the properties that make the daemon safe to leave running forever:
it can be absent, wrong, slow, or hostile and search must still be correct.
"""
import os, sys, json, socket, subprocess, tempfile, time, threading
from pathlib import Path

TOOLS = "/Users/YOUR_USERNAME/.memory/tools"
sys.path.insert(0, TOOLS)

FAILS = []


def check(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'}  {name}{'  ' + detail if detail else ''}")
    if not cond:
        FAILS.append(name)


# ---------------------------------------------------------------- no daemon
print("client with no daemon present")
tmp = tempfile.mkdtemp()
os.environ["MEMORY_DAEMON_STATE"] = tmp
import importlib
import daemon_client
importlib.reload(daemon_client)
daemon_client.spawn = lambda: False              # do not actually launch one
t = time.time()
r = daemon_client.vector_knn("anything", None, autostart=False)
check("returns None (not [])", r is None, f"got {r!r}")
check("fails fast", time.time() - t < 0.5, f"{(time.time()-t)*1000:.0f}ms")

# ------------------------------------------------------- unresponsive daemon
print("client against a socket that accepts and never replies")
sockpath = Path(tmp) / "sock"
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(str(sockpath)); srv.listen(4)
held = []
def accept_and_stall():
    try:
        c, _ = srv.accept(); held.append(c)      # accept, then never answer
    except OSError:
        pass
threading.Thread(target=accept_and_stall, daemon=True).start()
os.environ["MEMORY_DAEMON_TIMEOUT"] = "0.7"
importlib.reload(daemon_client)
daemon_client.spawn = lambda: False
t = time.time(); r = daemon_client.vector_knn("anything", None, autostart=False); el = time.time() - t
check("hung daemon returns None", r is None, f"got {r!r}")
check("bounded by the deadline", el < 2.0, f"{el*1000:.0f}ms")
for c in held:
    c.close()
srv.close(); sockpath.unlink(missing_ok=True)

# ------------------------------------------------------------ garbage daemon
print("client against a daemon returning junk")
def serve_once(reply):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(str(sockpath)); s.listen(1)
    def run():
        try:
            c, _ = s.accept(); c.recv(4096); c.sendall(reply); c.close()
        except OSError:
            pass
        s.close(); sockpath.unlink(missing_ok=True)
    th = threading.Thread(target=run, daemon=True); th.start()
    return th

importlib.reload(daemon_client)
OURS = daemon_client.DB          # the database this client believes it is reading


def reply(body):
    """Encode a reply that correctly claims OUR index, so identity is not the
    variable under test in the malformed-reply cases below."""
    body.setdefault("db", OURS)
    return json.dumps(body).encode() + b"\n"


for label, raw in [("not json", b"<html>hello\n"),
                   ("ok=false", reply({"ok": False, "err": "nope"})),
                   ("rows not a list", reply({"ok": True, "rows": "oops"}))]:
    th = serve_once(raw)
    importlib.reload(daemon_client); daemon_client.spawn = lambda: False
    r = daemon_client.vector_knn("q", None, autostart=False)
    check(f"{label} -> None", r is None, f"got {r!r}")
    th.join(timeout=2)

# an EMPTY result is a real answer and must NOT be confused with unavailable
th = serve_once(reply({"ok": True, "rows": []}))
importlib.reload(daemon_client); daemon_client.spawn = lambda: False
r = daemon_client.vector_knn("q", None, autostart=False)
check("empty rows -> [] not None", r == [], f"got {r!r}")
th.join(timeout=2)

# ------------------------------------------------------------ wrong index
# The one that actually happened: on 2026-07-30 a bake-off daemon serving a TRIAL
# COPY of the index bound the default socket and answered live searches. Its rows
# were chunk_ids from another database, fused into results read out of this one.
# Nothing raised. The client must refuse a reply that does not name its own index,
# and must not confuse "wrong daemon" with "no daemon" in the telemetry.
print("client against a daemon serving a DIFFERENT index")
for label, raw in [
        ("foreign db", reply({"ok": True, "rows": [[1, 0.9]], "db": "/tmp/other-index.sqlite"})),
        ("no db field", json.dumps({"ok": True, "rows": [[1, 0.9]]}).encode() + b"\n")]:
    th = serve_once(raw)
    importlib.reload(daemon_client); daemon_client.spawn = lambda: False
    r = daemon_client.vector_knn("q", None, autostart=False)
    check(f"{label} -> None (never fuses foreign chunk_ids)", r is None, f"got {r!r}")
    check(f"{label} -> recorded as 'foreign', not silence",
          daemon_client.last_reject == "foreign", f"got {daemon_client.last_reject!r}")
    th.join(timeout=2)

# Identity has to be resolved the same way on both sides, or a symlinked or
# non-canonical SEMANTIC_DB reads as a mismatch and silently disables a HEALTHY
# daemon -- a check that turns itself into the outage it exists to prevent.
th = serve_once(reply({"ok": True, "rows": [[7, 0.5]]}))
os.environ["SEMANTIC_DB"] = os.path.expanduser("~/.memory/./semantic-index.sqlite")
importlib.reload(daemon_client); daemon_client.spawn = lambda: False
r = daemon_client.vector_knn("q", None, autostart=False)
check("non-canonical SEMANTIC_DB still matches", r == [(7, 0.5)], f"got {r!r}")
th.join(timeout=2)
del os.environ["SEMANTIC_DB"]
importlib.reload(daemon_client)

# The daemon must actually SEND what the client requires. Asserted against the
# real module rather than a hand-written reply, so the two halves of the protocol
# cannot drift apart while both test suites keep passing.
src = Path(TOOLS, "memory-query-daemon").read_text()
check("daemon stamps identity on every reply",
      'resp.setdefault("db", IDENTITY_DB)' in src)
check("daemon resolves identity the same way the client does",
      "os.path.realpath(os.path.expanduser(DB))" in src)

# ------------------------------------------------------------ spawn cooldown
print("spawn rate limiting")
os.environ["MEMORY_DAEMON_SPAWN_COOLDOWN"] = "30"
importlib.reload(daemon_client)
calls = []
import subprocess as _sp
real_popen = _sp.Popen
_sp.Popen = lambda *a, **k: calls.append(a) or type("P", (), {"pid": 0})()
try:
    first = daemon_client.spawn()
    second = daemon_client.spawn()
    third = daemon_client.spawn()
finally:
    _sp.Popen = real_popen
check("first spawn attempts launch", first is True)
check("subsequent spawns suppressed", second is False and third is False)
check("exactly one process launched", len(calls) == 1, f"{len(calls)}")

# ------------------------------------------------- fusion rollback guarantee
print("fusion still degrades to arm A exactly")
import fusion
docs = [("memory", f"n{i}.md", f"s{i}", -3.0 - i, f"snip{i}") for i in range(6)]
out = fusion.fuse(docs, [], [], 4)
check("no arms -> arm A order, unchanged rows",
      [o[0] for o in out] == docs[:4] and all(o[1] is None for o in out))

# ---- rerank op: it must be impossible for reranking to break search ---------
# Reranking is a refinement layered on results that are already correct. Every
# way it can fail -- daemon down, model missing, malformed reply, wrong number of
# scores -- has to leave the caller's order alone rather than raise or truncate.
import daemon_client as dc

_real_request, _real_enabled = dc.request, dc.enabled
try:
    dc.request = lambda *a, **k: None                       # daemon unreachable
    check("daemon down -> None, no raise", dc.rerank("q", ["a", "b"]) is None)

    dc.request = lambda *a, **k: {"ok": False, "err": "cross-encoder error"}
    check("model unavailable -> None", dc.rerank("q", ["a", "b"]) is None)

    # A short score list is the dangerous one: zipped against the candidates it
    # would silently score the wrong passages rather than fail.
    dc.request = lambda *a, **k: {"ok": True, "db": dc.DB, "scores": [1.0]}
    check("score count mismatch -> None", dc.rerank("q", ["a", "b"]) is None)

    dc.request = lambda *a, **k: {"ok": True, "db": dc.DB, "scores": ["not", "numbers"]}
    check("non-numeric scores -> None", dc.rerank("q", ["a", "b"]) is None)

    # Identity is checked on EVERY op, not just the one that returns row ids.
    dc.request = lambda *a, **k: {"ok": True, "db": "/tmp/other.sqlite",
                                  "scores": [2.0, 1.0]}
    check("rerank from a foreign daemon -> None", dc.rerank("q", ["a", "b"]) is None)

    dc.request = lambda *a, **k: {"ok": True, "db": dc.DB, "scores": [2.0, 1.0]}
    check("well-formed reply -> floats", dc.rerank("q", ["a", "b"]) == [2.0, 1.0])

    # Never autostarts: a cold query returns its existing results now rather
    # than blocking on a model load it did not need.
    _spawned = []
    dc.spawn = lambda: _spawned.append(1)
    dc.request = lambda *a, **k: None
    dc.rerank("q", ["a", "b"])
    check("rerank never autostarts the daemon", not _spawned)

    dc.enabled = False
    check("disabled -> None", dc.rerank("q", ["a", "b"]) is None)
finally:
    dc.request, dc.enabled = _real_request, _real_enabled

print()
print("FAILED: " + ", ".join(FAILS) if FAILS else "all daemon contract tests pass")
sys.exit(1 if FAILS else 0)
