#!/usr/bin/env python3
"""A memory-mapped float32 matrix of every chunk embedding, and an exact KNN over it.

WHY THIS EXISTS. sqlite-vec's `vec0` KNN is a brute-force scan with no ANN index,
so its cost is linear in the corpus. That was documented as a watched ceiling with
a NOTE past 60k vectors. Measuring it properly changed the answer: the scan was
not slow because it is linear, it was slow because of PER-ROW OVERHEAD. The same
linear work as one BLAS matrix-vector product is ~8x faster at every size measured
on this machine (float32, dim 384, k=60, best-of-7):

      vectors     vec0      this
       10,000    8.0ms     0.3ms
       50,000   16.6ms     2.4ms
      100,000   32.8ms     4.5ms
      500,000  168.5ms    19.6ms
    1,000,000  329.1ms    40.4ms
    2,000,000       --    98.7ms

At the observed growth of this corpus (~2k prose vectors/month) that moves the
point where the vector arm starts to dominate a query from a few years out to
several decades out. **So the fix for the growth ceiling is not an ANN index.**
An ANN index (HNSW/DiskANN) would trade EXACT results for sublinear time and add
a second graph structure to keep consistent, to solve a problem that a 30-line
gemv already pushes past any horizon this corpus has. sqlite-vec's own ANN work
shipped in 0.1.10-alpha (2026-03-31, alpha) and is not something core memory
infrastructure that must run unattended should depend on. If this ever does need
to be faster, the next lever is int8 quantization with a float rescore of the top
few hundred -- still exact enough, still no graph, ~4x less memory traffic.

WHAT MAKES IT SAFE. The matrix is a DERIVED CACHE, never a source of truth. The
sqlite `vec_chunks` table remains authoritative and stays in place, so any doubt
about the matrix is resolved by ignoring it: `fusion.vector_knn` falls back to the
vec0 path and returns identical results, only slower. Validation is therefore
allowed to be strict and cheap -- a false rejection costs milliseconds, while a
false acceptance would serve results from a corpus that no longer exists.

Four things must agree or the matrix is refused:
  db           the resolved database path it was built from -- a matrix beside a
               trial copy of the index must never answer for the real one, the
               same lesson as daemon_client's identity check
  fingerprint  the embedding contract, so a model change invalidates it
  epoch        a counter bumped by EVERY vector write, including incremental
               `--only` builds that do not change the fingerprint. Without this
               a daemon would keep serving a matrix that is missing everything
               indexed since it started -- a silent recall hole, not an error
  shape        row count and dim against the live table
"""
import json, os
from pathlib import Path

import numpy as np

from embedder import CONTRACT

EPOCH_KEY = "vector_epoch"


def paths(dbpath):
    """Matrix files live BESIDE their database and are named after it.

    Deriving the name from the db path rather than a fixed location is what makes
    a second index (a trial copy, a bake-off) get its own matrix instead of
    quietly sharing one.
    """
    base = Path(os.path.realpath(os.path.expanduser(str(dbpath))))
    return (base.with_suffix(base.suffix + ".vectors.npy"),
            base.with_suffix(base.suffix + ".vectors.ids.npy"),
            base.with_suffix(base.suffix + ".vectors.json"))


def live_shape(db):
    """(count, max_id, checksum) of the authoritative table.

    The checksum is a plain SUM over chunk_ids. It is not cryptographic and does
    not need to be: it exists to catch a same-count rebuild where different rows
    survived, which count alone would wave through.
    """
    row = db.execute("SELECT COUNT(*), COALESCE(MAX(chunk_id),0), "
                     "COALESCE(SUM(chunk_id),0) FROM vec_chunks").fetchone()
    return int(row[0]), int(row[1]), int(row[2])


def bump_epoch(db, get_meta, set_meta):
    """Invalidate every existing matrix for this database. Called after any write."""
    try:
        cur = int(get_meta(db, EPOCH_KEY, "0") or 0)
    except (TypeError, ValueError):
        cur = 0
    set_meta(db, EPOCH_KEY, cur + 1)
    return cur + 1


def build(db, dbpath, get_meta):
    """Write the matrix for the CURRENT contents of vec_chunks.

    Rows are streamed in chunk_id order and written straight into a memmap, so
    peak memory is one batch rather than the whole corpus -- the build must not
    become the reason the nightly job needs 1.5GB at some future size.
    """
    vec_npy, ids_npy, meta_json = paths(dbpath)
    count, max_id, checksum = live_shape(db)
    dim = CONTRACT["dim"]
    if count == 0:
        for p in (vec_npy, ids_npy, meta_json):
            try:
                p.unlink()
            except FileNotFoundError:
                pass
        return {"rows": 0, "written": False, "reason": "no vectors"}

    tmp_vec = vec_npy.with_suffix(".tmp")
    tmp_ids = ids_npy.with_suffix(".tmp")
    mat = np.lib.format.open_memmap(tmp_vec, mode="w+", dtype=np.float32,
                                    shape=(count, dim))
    ids = np.empty(count, dtype=np.int64)
    i = 0
    for cid, blob in db.execute("SELECT chunk_id, embedding FROM vec_chunks "
                               "ORDER BY chunk_id"):
        if i >= count:                     # table grew mid-read; epoch will reject
            break
        v = np.frombuffer(blob, dtype=np.float32)
        if v.size != dim:
            continue
        mat[i] = v
        ids[i] = cid
        i += 1
    mat.flush()
    del mat
    # Written through an open handle, not by path: np.save appends ".npy" to any
    # path that lacks it, so saving to a ".tmp" name silently produces
    # "....tmp.npy" and the rename below then fails on a file that was never there.
    with open(tmp_ids, "wb") as fh:
        np.save(fh, ids[:i])

    # Written to a temp name and renamed, so a crash mid-build leaves the previous
    # matrix intact rather than a truncated one. A half-written cache that still
    # validates is the worst possible state for something allowed to answer queries.
    meta = {"db": str(Path(os.path.realpath(os.path.expanduser(str(dbpath))))),
            "fingerprint": get_meta(db, "embed_fingerprint", "") or "",
            "epoch": int(get_meta(db, EPOCH_KEY, "0") or 0),
            "rows": int(i), "dim": dim, "max_id": max_id, "checksum": checksum,
            "built_at": int(__import__("time").time())}
    os.replace(tmp_vec, vec_npy)
    os.replace(tmp_ids, ids_npy)
    meta_json.write_text(json.dumps(meta, indent=2))
    return {"rows": int(i), "written": True, "bytes": vec_npy.stat().st_size}


class Matrix:
    """A loaded, validated matrix. `revalidate()` is cheap enough to call per query."""

    def __init__(self, mat, ids, meta, dbpath):
        self.mat, self.ids, self.meta, self.dbpath = mat, ids, meta, dbpath

    @property
    def rows(self):
        return int(self.mat.shape[0])

    def revalidate(self, db, get_meta):
        """True while this matrix still describes the database.

        Only the epoch is checked here, not the full shape: the epoch is a single
        meta read and is bumped by every writer, so it catches incremental builds
        that leave the fingerprint alone. Shape and identity were checked at load.
        """
        try:
            return int(get_meta(db, EPOCH_KEY, "0") or 0) == int(self.meta.get("epoch", -1))
        except (TypeError, ValueError):
            return False

    def knn(self, qvec, k):
        """Exact top-k by cosine, returned as (chunk_id, l2_distance) nearest-first.

        Embeddings are L2-normalized by contract, so cosine is a plain dot product
        and the L2 distance vec0 would report is sqrt(2-2cos) -- computed here so
        callers see the same units either way and nothing downstream has to know
        which path answered.
        """
        q = np.asarray(qvec, dtype=np.float32).reshape(-1)
        if q.size != self.mat.shape[1]:
            raise ValueError(f"query dim {q.size} != matrix dim {self.mat.shape[1]}")
        sims = self.mat @ q
        k = max(1, min(int(k), sims.shape[0]))
        # argpartition, not argsort: the full sort is O(n log n) over the entire
        # corpus to produce sixty rows, and at a million vectors that sort costs
        # more than the matrix product it is sorting.
        idx = np.argpartition(-sims, k - 1)[:k]
        # lexsort, not argsort: this corpus contains genuine duplicate files (an
        # app bundle carries a second copy of its own source, two crawls seconds
        # apart), whose distances differ only in the last float32 ulp. Which copy
        # wins is then decided by rounding, and an unstable sort can decide it
        # differently between runs on identical input. Breaking ties on chunk_id
        # makes this path reproducible. It does NOT make it match vec0 -- vec0
        # rounds its own way and no local choice can change that -- so the
        # equivalence test asserts distance equality, not id equality.
        idx = idx[np.lexsort((self.ids[idx], -sims[idx]))]
        out = []
        for j in idx:
            cos = float(sims[j])
            out.append((int(self.ids[j]), float(np.sqrt(max(0.0, 2.0 - 2.0 * cos)))))
        return out


def load(db, dbpath, get_meta):
    """Return a validated Matrix, or None to use the vec0 path.

    None is not an error and is never logged as one -- an absent or superseded
    matrix simply means the slower exact path answers this query.
    """
    vec_npy, ids_npy, meta_json = paths(dbpath)
    try:
        meta = json.loads(meta_json.read_text())
    except (OSError, ValueError):
        return None
    resolved = str(Path(os.path.realpath(os.path.expanduser(str(dbpath)))))
    if meta.get("db") != resolved:
        return None
    if meta.get("dim") != CONTRACT["dim"]:
        return None
    live_fp = get_meta(db, "embed_fingerprint", "") or ""
    if not live_fp or meta.get("fingerprint") != live_fp:
        return None
    try:
        if int(get_meta(db, EPOCH_KEY, "0") or 0) != int(meta.get("epoch", -1)):
            return None
    except (TypeError, ValueError):
        return None
    count, max_id, checksum = live_shape(db)
    if (meta.get("rows") != count or meta.get("max_id") != max_id
            or meta.get("checksum") != checksum):
        return None
    try:
        mat = np.load(vec_npy, mmap_mode="r")
        ids = np.load(ids_npy)
    except (OSError, ValueError):
        return None
    if mat.shape != (count, CONTRACT["dim"]) or ids.shape != (count,):
        return None
    return Matrix(mat, ids, meta, resolved)


def describe(db, dbpath, get_meta):
    """Human/JSON status for the health checks."""
    vec_npy, _ids, meta_json = paths(dbpath)
    if not meta_json.exists():
        return {"state": "absent", "detail": "no matrix built yet (vec0 path in use)"}
    m = load(db, dbpath, get_meta)
    if m is None:
        return {"state": "stale",
                "detail": "matrix superseded by a newer index; rebuild with "
                          "memory-vector-build --matrix (vec0 path in use)"}
    return {"state": "ok", "rows": m.rows,
            "bytes": vec_npy.stat().st_size if vec_npy.exists() else 0,
            "epoch": m.meta.get("epoch")}
