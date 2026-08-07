#!/usr/bin/env python3
"""Client side of the warm query daemon. Stdlib only — that is the whole point.

memory-semantic-query runs under the system python, which has no numpy, no
onnxruntime and no sqlite-vec. Talking to the daemon over a socket lets it get
vector results without importing any of that, so the fast path costs a socket
round trip instead of ~95ms of module imports and session setup.

Every function here returns None instead of raising. A caller that gets None
falls back to its own in-process path; it must never have to reason about why.
"""
import os, json, socket, subprocess, sys, time
from pathlib import Path

STATE = Path(os.environ.get(
    "MEMORY_DAEMON_STATE",
    str(Path.home() / ".local/state/memory-query-daemon"))).expanduser()
SOCK = STATE / "sock"
SPAWN_STAMP = STATE / "last-spawn"

PROTOCOL = 1
VENV_PY = os.path.expanduser(
    os.environ.get("MEMORY_VENV_PY", "~/.local/share/memory-venv/bin/python"))
DAEMON = str(Path(__file__).resolve().parent / "memory-query-daemon")

# WHICH INDEX THE ANSWER IS ABOUT. The socket path is not an identity: any daemon
# started with a different SEMANTIC_DB but the default MEMORY_DAEMON_STATE binds
# this same socket and answers these same requests. That is not hypothetical — a
# bake-off daemon serving a trial copy of the index squatted this socket on
# 2026-07-30 and answered live searches for several minutes before it was noticed.
# Its rows were chunk_ids from a DIFFERENT database, fused straight into results
# read out of this one, so they pointed at whatever those ids happened to mean
# here. No error, no warning, just wrong answers.
#
# The daemon's own check_fresh() cannot catch this: it validates the daemon
# against ITS index, and a foreign daemon is perfectly consistent with its own.
# Only the client knows which index it is reading, so the check belongs here.
#
# Identity is the resolved DB PATH, not the embedding fingerprint. The fingerprint
# identifies the model CONTRACT, so two daemons on two different databases share
# one — it would have passed the very incident it is meant to stop. Path equality
# is the stronger claim, and it is sufficient: if the daemon is serving this exact
# database, its own fingerprint check already guarantees the vectors in it agree
# with the query embedding it made.
#
# Resolved identically on both sides (same default, expanduser, realpath) so a
# symlink or a trailing `/./` cannot read as a mismatch and turn a healthy daemon
# off. Duplicated rather than imported because this module is stdlib-only by
# construction and the daemon's module is not.
DB = os.path.realpath(os.path.expanduser(
    os.environ.get("SEMANTIC_DB", "~/.memory/semantic-index.sqlite")))

# Set when a reply was refused for identity. Read by memory-semantic-query so the
# per-query telemetry says `foreign` rather than the generic `none`: a socket held
# by the wrong daemon looks exactly like a daemon that never started, and the
# repair for the two is opposite (kill the squatter vs. start one).
last_reject = None

# A whole search should feel instant. If the daemon cannot answer in this long it
# has stopped being the fast path, and the in-process fallback is the better deal.
DEADLINE = float(os.environ.get("MEMORY_DAEMON_TIMEOUT", "1.5"))
# Floor between spawn attempts. Without it a daemon that dies on startup would be
# respawned by every single query — turning one broken component into a fork bomb.
SPAWN_COOLDOWN = float(os.environ.get("MEMORY_DAEMON_SPAWN_COOLDOWN", "60"))

enabled = os.environ.get("MEMORY_DAEMON", "1") != "0"


def request(payload, timeout=DEADLINE):
    """One request/response. Returns the decoded dict, or None if unreachable."""
    if not enabled:
        return None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(str(SOCK))
    except (OSError, socket.timeout):
        return None
    try:
        s.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                return None
            buf += chunk
        return json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    except (OSError, socket.timeout, ValueError):
        return None
    finally:
        try:
            s.close()
        except OSError:
            pass


def spawn():
    """Start the daemon detached, rate-limited. Returns True if we launched one.

    Deliberately does NOT wait for it: this query is already falling back, and
    blocking here would spend the startup cost we are trying to avoid. The daemon
    is for the NEXT query.
    """
    if not enabled or not os.path.exists(VENV_PY) or not os.path.exists(DAEMON):
        return False
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        try:
            if time.time() - SPAWN_STAMP.stat().st_mtime < SPAWN_COOLDOWN:
                return False
        except OSError:
            pass
        SPAWN_STAMP.touch()
        with open(os.devnull, "r+b") as null:
            subprocess.Popen(
                [VENV_PY, DAEMON],
                stdin=null, stdout=null, stderr=null,
                start_new_session=True,       # survive this process exiting
                close_fds=True)
        return True
    except Exception:
        return False


def _same_index(r):
    """True if this reply came from a daemon serving OUR database.

    A reply with no `db` field is refused, not trusted. That field has been in
    every response since protocol 1 gained it, so its absence means the socket is
    held by something older or something else — either way not a daemon whose
    chunk_ids are safe to fuse into this index's results. Refusing costs one
    keyword-only query; accepting costs silently wrong answers.
    """
    global last_reject
    if r.get("db") != DB:
        last_reject = "foreign"
        return False
    return True


last_qrows = None            # arm D rows from the most recent vector_knn


def vector_knn(question, root=None, autostart=True):
    """Vector arm via the daemon. Returns rows, or None to use the local path.

    None means "no answer from the daemon", NOT "no neighbours" — an empty list is
    a real answer and is returned as such. Conflating those two is exactly the bug
    that once made a dead vector arm look like a working one.
    """
    # Reset FIRST. This is a side channel, and a side channel that keeps its
    # previous value across an early return is how one query's arm D rows end up
    # ranking the next query's results -- silently, and only under the conditions
    # that make the daemon bail out.
    global last_qrows
    last_qrows = None
    if not enabled:
        return None
    r = request({"v": PROTOCOL, "op": "knn", "q": question, "root": root})
    if r is None:
        if autostart:
            spawn()
        return None
    if not r.get("ok"):
        return None
    # Deliberately NOT followed by spawn(): the socket is held and a new daemon
    # could not bind it anyway. Degrade to the keyword arms and let the telemetry
    # say why, rather than spinning on a spawn that cannot succeed.
    if not _same_index(r):
        return None
    rows = r.get("rows")
    if not isinstance(rows, list):
        return None
    # Arm D travels in the same reply. A daemon built before arm D existed simply
    # omits the field, which lands as None -> arm absent -> pre-arm ordering. That
    # is the intended behaviour during a rolling restart, not an error, so it is
    # not logged as one.
    qrows = r.get("qrows")
    last_qrows = ([tuple(x) for x in qrows] if isinstance(qrows, list) else None)
    return [tuple(x) for x in rows]


def rerank(question, passages, timeout=None, model=None):
    """Cross-encoder scores from the daemon, or None if it cannot answer.

    Never autostarts. Reranking is a refinement on results that already exist,
    so a cold query should return those results now rather than block on an
    80MB model load — the daemon the vector arm already asked for will be warm
    by the next query. Same None-vs-[] discipline as vector_knn: None means no
    answer, and the caller keeps its existing order untouched.

    `model` names which reranker to score with; None means the daemon's default.
    A caller fusing several orders asks once per model, and each ask fails
    independently — one unavailable model costs its vote, not the whole rerank.
    """
    if not enabled or not passages:
        return None
    payload = {"v": PROTOCOL, "op": "rerank", "q": question,
               "passages": list(passages)}
    if model:
        payload["model"] = model
    r = request(payload, timeout=DEADLINE if timeout is None else timeout)
    if r is None or not r.get("ok"):
        return None
    # Reranking scores passages the CALLER supplied, so a foreign daemon could not
    # corrupt the result set the way it can through knn — but a daemon on another
    # index is also running whatever reranker that run configured, and the point of
    # an identity check is that one answer from an unidentified peer is not more
    # trustworthy than another. Same rule everywhere.
    if not _same_index(r):
        return None
    # A reply for a different model than the one asked for would silently
    # attribute one reranker's opinion to another inside a multi-model fusion.
    if (r.get("model") or None) != (model or None):
        return None
    scores = r.get("scores")
    if not isinstance(scores, list) or len(scores) != len(passages):
        return None
    try:
        return [float(s) for s in scores]
    except (TypeError, ValueError):
        return None


if __name__ == "__main__":
    q = " ".join(sys.argv[1:]) or "ping"
    t = time.time()
    print(json.dumps(request({"v": PROTOCOL, "op": "ping"}), indent=2))
    print(f"ping {(time.time()-t)*1000:.1f}ms")
