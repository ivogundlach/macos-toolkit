#!/usr/bin/env python3
"""Contract tests for the derived embedding matrix (tools/vector_matrix.py).

The matrix is an ACCELERATOR sitting in front of the authoritative vec0 table,
and every way it can fail is silent: it answers, quickly, with results that look
exactly as plausible as the right ones. So what is pinned here is not "does it
return rows" but the four ways it could be wrong without anyone noticing.

  1. It answers for a corpus that has moved on. `--only` builds add and remove
     vectors without touching the embedding fingerprint, so a fingerprint check
     alone would wave through a matrix missing every note written since it was
     built -- a recall hole with no error anywhere.
  2. It answers for a DIFFERENT database. Matrix files are named after their db,
     but a copied or renamed index would otherwise inherit its neighbour's
     matrix. Same lesson as the daemon identity check.
  3. It answers differently from vec0. A fast accelerator that ranks subtly
     differently is worse than none: the results still look right.
  4. It stops existing and takes search down with it. It must be droppable at
     any moment, with the vec0 path picking up unchanged.

Everything here builds its own tiny index in a temp dir, so the suite is
constant-time and safe to run from the dashboard health check.
"""
import os, sys, json, shutil, tempfile, sqlite3
from pathlib import Path

import numpy as np

TOOLS = "/Users/YOUR_USERNAME/.memory/tools"
sys.path.insert(0, TOOLS)

import chunk_store as cs
import vector_matrix as vm
import fusion
from embedder import CONTRACT, fingerprint

DIM = CONTRACT["dim"]
FAILS = []


def check(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'}  {name}{'  ' + detail if detail else ''}")
    if not cond:
        FAILS.append(name)


def unit(rng, n):
    v = rng.standard_normal((n, DIM)).astype(np.float32)
    return v / np.linalg.norm(v, axis=1, keepdims=True)


def make_index(tmp, n_files=12, per_file=3, seed=7, dupes=True):
    """A real index: real schema, real vec0 table, real fingerprint."""
    path = Path(tmp) / "test-index.sqlite"
    db, vec = cs.open_db(str(path), write=True)
    assert vec, "sqlite-vec unavailable; the matrix test needs a real vec0 table"
    cs.set_meta(db, "embed_fingerprint", fingerprint())
    rng = np.random.default_rng(seed)
    for f in range(n_files):
        vecs = unit(rng, per_file)
        if dupes and f > 0 and f % 4 == 0:
            # An exact duplicate file, which this corpus really does contain
            # (an app bundle carrying a second copy of its own source). Ties
            # between duplicates are where ordering becomes ambiguous.
            vecs = prev
        prev = vecs
        chunks = [{"heading": f"h{f}", "text": f"body of file {f} chunk {i} " * 4,
                   "path_tokens": f"file{f}", "ordinal": i} for i in range(per_file)]
        cs.replace_file(db, "test", f"dir/file{f}.md", f"/abs/file{f}.md",
                        f"hash{f}", chunks, vectors=vecs)
    db.commit()
    return path, db


tmp = tempfile.mkdtemp(prefix="matrix-test-")
try:
    path, db = make_index(tmp)
    n_live = db.execute("SELECT COUNT(*) FROM vec_chunks").fetchone()[0]

    # ------------------------------------------------------------ builds/loads
    print("build and load")
    res = vm.build(db, str(path), cs.get_meta)
    check("build writes every live vector", res.get("rows") == n_live,
          f"{res.get('rows')} of {n_live}")
    m = vm.load(db, str(path), cs.get_meta)
    check("loads and validates", m is not None and m.rows == n_live)

    # ------------------------------------------------- agrees with vec0 exactly
    # Not id-for-id: vec0 rounds its own way, and on duplicate vectors the two
    # engines can pick different copies at the same distance. What must hold is
    # that the DISTANCES match rank for rank -- that is the claim "same results",
    # stated in the only form that is true.
    print("agreement with the authoritative vec0 path")
    rng = np.random.default_rng(99)
    worst_d = 0.0
    worst_set = 0
    for q in unit(rng, 25):
        k = min(20, n_live)
        raw = db.execute("SELECT chunk_id, distance FROM vec_chunks "
                         "WHERE embedding MATCH ? AND k = ? ORDER BY distance",
                         (q.tobytes(), k)).fetchall()
        mine = m.knn(q, k)
        worst_d = max(worst_d, max(abs(a[1] - b[1]) for a, b in zip(raw, mine)))
        worst_set = max(worst_set, len(set(c for c, _ in raw) ^ set(c for c, _ in mine)))
    check("distance at every rank matches vec0", worst_d < 1e-5, f"max delta {worst_d:.2e}")
    check("returns the same result set", worst_set == 0, f"max symmetric diff {worst_set}")

    # ------------------------------------------------------------ deterministic
    print("determinism")
    q = unit(np.random.default_rng(3), 1)[0]
    runs = [m.knn(q, min(20, n_live)) for _ in range(5)]
    check("identical output across repeated calls", all(r == runs[0] for r in runs))
    ids = [c for c, _ in runs[0]]
    dist = [round(d, 6) for _, d in runs[0]]
    tied_ok = all(ids[i] < ids[i + 1] for i in range(len(ids) - 1) if dist[i] == dist[i + 1])
    check("ties break on chunk_id, not on float noise", tied_ok)

    # ------------------------------------------------------ the corpus moves on
    # The failure this catches: an incremental build that changes the corpus
    # without changing the model. No error is raised anywhere; the matrix simply
    # keeps answering from a corpus that no longer exists.
    print("a matrix whose corpus has moved on is refused")
    before = int(cs.get_meta(db, vm.EPOCH_KEY, "0"))
    live = vm.load(db, str(path), cs.get_meta)
    cs.replace_file(db, "test", "dir/NEW.md", "/abs/NEW.md", "h",
                    [{"heading": "n", "text": "a new note " * 20,
                      "path_tokens": "new", "ordinal": 0}],
                    vectors=unit(np.random.default_rng(11), 1))
    db.commit()
    after = int(cs.get_meta(db, vm.EPOCH_KEY, "0"))
    check("an incremental write bumps the epoch", after > before, f"{before} -> {after}")
    check("the already-loaded matrix revalidates as stale",
          live is not None and not live.revalidate(db, cs.get_meta))
    check("a fresh load refuses it", vm.load(db, str(path), cs.get_meta) is None)
    check("describe() reports stale, not ok",
          vm.describe(db, str(path), cs.get_meta)["state"] == "stale")
    vm.build(db, str(path), cs.get_meta)
    check("rebuilding restores it", vm.load(db, str(path), cs.get_meta) is not None)

    # A delete must invalidate too -- vectors leaving is as wrong as vectors
    # arriving, and count alone would not notice a same-count churn.
    cs.delete_file(db, "test", "dir/NEW.md")
    db.commit()
    check("a delete invalidates as well", vm.load(db, str(path), cs.get_meta) is None)
    vm.build(db, str(path), cs.get_meta)

    # ------------------------------------------------------------- wrong corpus
    print("a matrix belonging to another index is refused")
    meta_p = vm.paths(path)[2]
    good = json.loads(meta_p.read_text())

    for label, mutate in [
        ("db path", lambda m: m.update(db="/somewhere/else.sqlite")),
        ("fingerprint", lambda m: m.update(fingerprint="a-different-model")),
        ("row count", lambda m: m.update(rows=m["rows"] + 1)),
        ("chunk_id checksum", lambda m: m.update(checksum=m["checksum"] + 1)),
        ("dim", lambda m: m.update(dim=DIM + 1)),
    ]:
        bad = dict(good)
        mutate(bad)
        meta_p.write_text(json.dumps(bad))
        check(f"refused on {label} mismatch", vm.load(db, str(path), cs.get_meta) is None)
    meta_p.write_text(json.dumps(good))
    check("accepted again once restored", vm.load(db, str(path), cs.get_meta) is not None)

    # An index with no fingerprint recorded must not be matched by a matrix that
    # also has none -- empty must never equal empty.
    cs.set_meta(db, "embed_fingerprint", "")
    check("empty fingerprint never validates",
          vm.load(db, str(path), cs.get_meta) is None)
    cs.set_meta(db, "embed_fingerprint", good["fingerprint"])

    # ------------------------------------------------------------- droppability
    print("search survives the matrix disappearing")
    m = vm.load(db, str(path), cs.get_meta)
    q = unit(np.random.default_rng(5), 1)[0]
    with_m = fusion.vector_knn(db, q, root="test", matrix=m)
    for p in vm.paths(path):
        p.unlink(missing_ok=True)
    check("gone matrix loads as None, not an error",
          vm.load(db, str(path), cs.get_meta) is None)
    check("describe() reports absent",
          vm.describe(db, str(path), cs.get_meta)["state"] == "absent")
    without = fusion.vector_knn(db, q, root="test", matrix=None)
    check("fusion returns results either way", bool(without) and bool(with_m))
    # Set, not list: this fixture plants exact duplicate files on purpose, and
    # which copy of a duplicate lands at which rank is decided by float32
    # rounding that the two engines do differently. Demanding list equality here
    # would be demanding that two correct answers round identically, and the
    # test would fail for a reason that is not a defect. The distance check
    # above is what pins ranking quality; this pins that nothing goes missing.
    check("and the same ones", set(r[1] for r in without) == set(r[1] for r in with_m),
          f"{len(without)} vs {len(with_m)}")

    # A corrupt matrix must behave like an absent one, not take search down.
    print("a corrupt matrix behaves like an absent one")
    vm.build(db, str(path), cs.get_meta)
    vec_npy = vm.paths(path)[0]
    vec_npy.write_bytes(b"not a numpy file")
    check("garbage on disk loads as None", vm.load(db, str(path), cs.get_meta) is None)
    check("fusion still answers", bool(fusion.vector_knn(db, q, root="test", matrix=None)))

    # ---------------------------------------------------------------- empty db
    print("an index with no vectors at all")
    empty_dir = tempfile.mkdtemp(prefix="matrix-empty-")
    ep = Path(empty_dir) / "empty.sqlite"
    edb, _ = cs.open_db(str(ep), write=True)
    cs.set_meta(edb, "embed_fingerprint", good["fingerprint"])
    r = vm.build(edb, str(ep), cs.get_meta)
    check("build declines rather than writing an empty matrix", r.get("rows") == 0)
    check("load returns None", vm.load(edb, str(ep), cs.get_meta) is None)
    edb.close()
    shutil.rmtree(empty_dir, ignore_errors=True)

    db.close()
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print(f"\n{'FAILED: ' + ', '.join(FAILS) if FAILS else 'all matrix contracts hold'}")
sys.exit(1 if FAILS else 0)
