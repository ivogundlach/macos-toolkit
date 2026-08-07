#!/usr/bin/env python3
"""Arm D: vectors over the agy-GENERATED QUESTIONS, matched query-to-question.

WHY THIS EXISTS. The dominant remaining failure was never "the answer is not in
the corpus" — it was a query and a document that mean the same thing in
different words. A triage of the 112-case gold set put 4 of 15 misses outside
the candidate pool entirely, and every one of them was this shape:

    asked:  <a question about when a news tool stopped needing its own API key>
    doc's generated question: "how does the Last30Days tool run planning
                               without external API keys?"

(the query side is paraphrased on purpose: it is a live gold-set question, and
quoting it in an indexed file makes this file the top hit for it -- a comment in
semantic-agy-build.py did exactly that once, see memory-retrieval-eval)

Those two sentences share almost no terms, so BM25 cannot connect them, and the
vector arm could not either — it embeds chunk BODIES, so it was still comparing
a question against prose. The enrichment pass already writes ~5 generated
questions per document; this arm embeds those and compares question to question.

Matching in one space is the whole point. A bi-encoder asked to place a short
interrogative near a long expository passage is doing the hard asymmetric job it
is weakest at; asked whether two questions mean the same thing, it is doing the
easy symmetric one. The expansion is generated once at index time by a model
that had the whole document in front of it, which is what makes this cheaper and
better-informed than expanding the query at search time.

WHAT IT COSTS. 2,739 docs carry 14,279 questions: a 21MB float32 matrix and one
extra gemv per query (~4ms at this size, see vector_matrix.py for the scaling
measurements). The query vector is the one the vector arm already computed, so
the marginal query cost is the product and the aggregation, nothing else.

SAFETY. Same shape as the vector matrix, one layer down: the `qvec` TABLE is
authoritative and the .npy matrix is a derived cache validated on db path,
fingerprint, epoch and shape. `qvec` is a PLAIN table, deliberately not a vec0
one — this arm must not be able to take the index down with it if the sqlite-vec
extension is missing, and a plain BLOB column is readable by any python that can
open the file. If the matrix is stale the table answers directly; if the table is
empty the arm returns [] and fusion simply has one less arm, which is the same
way the vector arm degrades.
"""
import hashlib
import json
import os
import re
from pathlib import Path

import numpy as np

from embedder import CONTRACT

EPOCH_KEY = "question_epoch"
# Questions shorter than this are agy artefacts ("Why", a dangling fragment from
# a truncated generation) rather than questions. They embed to noise and would
# each occupy a row and a chance to win a slot.
MIN_Q_CHARS = 12
MAX_Q_CHARS = 300

SCHEMA = """
CREATE TABLE IF NOT EXISTS qvec (
    qid INTEGER PRIMARY KEY,
    root_tag TEXT NOT NULL,
    rel_path TEXT NOT NULL,
    qhash TEXT NOT NULL,
    question TEXT NOT NULL,
    embedding BLOB NOT NULL,
    UNIQUE(root_tag, rel_path, qhash)
);
CREATE INDEX IF NOT EXISTS qvec_doc ON qvec(root_tag, rel_path);
"""

# Questions arrive as one blob per document. agy is asked for a list and mostly
# returns one per line, but it also runs them together on a single line and
# emits bare symptom statements with no question mark at all ("Symptom: the
# troubleshooting steps did not change the behavior"). Splitting on newlines
# alone silently fused five questions into one 400-char string that embedded to
# their average and matched none of them. Split on either.
_SPLIT = re.compile(r"(?<=\?)\s+|\n+")


def split_questions(blob):
    """The individual questions in one document's `questions` field."""
    if not blob:
        return []
    out, seen = [], set()
    for part in _SPLIT.split(blob):
        q = " ".join(part.split()).strip()
        if len(q) < MIN_Q_CHARS:
            continue
        q = q[:MAX_Q_CHARS]
        low = q.lower()
        if low in seen:            # agy repeats itself across near-duplicate docs
            continue
        seen.add(low)
        out.append(q)
    return out


def qhash(q):
    return hashlib.sha256(q.encode("utf-8")).hexdigest()[:16]


def paths(dbpath):
    base = Path(os.path.realpath(os.path.expanduser(str(dbpath))))
    return (base.with_suffix(base.suffix + ".qvectors.npy"),
            base.with_suffix(base.suffix + ".qvectors.ids.npy"),
            base.with_suffix(base.suffix + ".qvectors.json"))


def ensure_schema(db):
    db.executescript(SCHEMA)


def live_shape(db):
    row = db.execute("SELECT COUNT(*), COALESCE(MAX(qid),0), COALESCE(SUM(qid),0) "
                     "FROM qvec").fetchone()
    return int(row[0]), int(row[1]), int(row[2])


def bump_epoch(db, get_meta, set_meta):
    try:
        cur = int(get_meta(db, EPOCH_KEY, "0") or 0)
    except (TypeError, ValueError):
        cur = 0
    set_meta(db, EPOCH_KEY, cur + 1)
    return cur + 1


def build(db, embed_passages, get_meta, set_meta, batch=64, progress=None):
    """Sync `qvec` with the current `docs.questions`. Incremental by content hash.

    Only questions whose exact text is not already stored get embedded, so a
    nightly run over an unchanged corpus embeds nothing and costs one scan. The
    hash is over the question text alone, not the document, so re-enriching a
    file that produced the same questions is free and moving a question between
    documents only rewrites a row.
    """
    ensure_schema(db)
    want = {}                       # (root_tag, rel_path, qhash) -> question
    for root_tag, rel_path, blob in db.execute(
            "SELECT root_tag, rel_path, questions FROM docs "
            "WHERE questions IS NOT NULL AND questions != ''"):
        for q in split_questions(blob):
            want[(root_tag, rel_path, qhash(q))] = q

    have = {(r[0], r[1], r[2]) for r in db.execute(
        "SELECT root_tag, rel_path, qhash FROM qvec")}

    stale = have - set(want)
    fresh = [k for k in want if k not in have]

    for i in range(0, len(stale), 400):
        chunk = list(stale)[i:i + 400]
        db.executemany("DELETE FROM qvec WHERE root_tag=? AND rel_path=? AND qhash=?",
                       chunk)

    added = 0
    for i in range(0, len(fresh), batch):
        keys = fresh[i:i + batch]
        vecs = embed_passages([want[k] for k in keys])
        rows = []
        for k, v in zip(keys, vecs):
            v = np.asarray(v, dtype=np.float32).reshape(-1)
            if v.size != CONTRACT["dim"]:
                continue
            rows.append((k[0], k[1], k[2], want[k], v.tobytes()))
        db.executemany(
            "INSERT OR REPLACE INTO qvec(root_tag, rel_path, qhash, question, embedding) "
            "VALUES (?,?,?,?,?)", rows)
        added += len(rows)
        if progress and (i // batch) % 10 == 0:
            progress(added, len(fresh))

    if added or stale:
        db.commit()
        bump_epoch(db, get_meta, set_meta)
    return {"questions": len(want), "added": added, "removed": len(stale)}


def build_matrix(db, dbpath, get_meta):
    """Write the derived matrix for the current `qvec`."""
    vec_npy, ids_npy, meta_json = paths(dbpath)
    count, max_id, checksum = live_shape(db)
    dim = CONTRACT["dim"]
    if count == 0:
        for p in (vec_npy, ids_npy, meta_json):
            try:
                p.unlink()
            except FileNotFoundError:
                pass
        return {"rows": 0, "written": False, "reason": "no question vectors"}

    tmp_vec, tmp_ids = vec_npy.with_suffix(".tmp"), ids_npy.with_suffix(".tmp")
    mat = np.lib.format.open_memmap(tmp_vec, mode="w+", dtype=np.float32,
                                    shape=(count, dim))
    ids = np.empty(count, dtype=np.int64)
    i = 0
    for qid, blob in db.execute("SELECT qid, embedding FROM qvec ORDER BY qid"):
        if i >= count:
            break
        v = np.frombuffer(blob, dtype=np.float32)
        if v.size != dim:
            continue
        mat[i] = v
        ids[i] = qid
        i += 1
    mat.flush()
    del mat
    with open(tmp_ids, "wb") as fh:
        np.save(fh, ids[:i])
    meta = {"db": str(Path(os.path.realpath(os.path.expanduser(str(dbpath))))),
            "fingerprint": get_meta(db, "embed_fingerprint", "") or "",
            "epoch": int(get_meta(db, EPOCH_KEY, "0") or 0),
            "rows": int(i), "dim": dim, "max_id": max_id, "checksum": checksum,
            "built_at": int(__import__("time").time())}
    os.replace(tmp_vec, vec_npy)
    os.replace(tmp_ids, ids_npy)
    meta_json.write_text(json.dumps(meta, indent=2))
    return {"rows": int(i), "written": True, "bytes": vec_npy.stat().st_size}


class QuestionMatrix:
    def __init__(self, mat, ids, meta, dbpath):
        self.mat, self.ids, self.meta, self.dbpath = mat, ids, meta, dbpath

    @property
    def rows(self):
        return int(self.mat.shape[0])

    def revalidate(self, db, get_meta):
        try:
            return int(get_meta(db, EPOCH_KEY, "0") or 0) == int(self.meta.get("epoch", -1))
        except (TypeError, ValueError):
            return False

    def knn(self, qvec, k):
        """Exact top-k questions by cosine, as (qid, similarity) nearest-first."""
        q = np.asarray(qvec, dtype=np.float32).reshape(-1)
        if q.size != self.mat.shape[1]:
            raise ValueError(f"query dim {q.size} != matrix dim {self.mat.shape[1]}")
        sims = self.mat @ q
        k = max(1, min(int(k), sims.shape[0]))
        idx = np.argpartition(-sims, k - 1)[:k]
        # Same tie discipline as vector_matrix: duplicate files produce identical
        # questions with distances differing in the last ulp, and an unstable
        # sort would order them differently between runs on identical input.
        idx = idx[np.lexsort((self.ids[idx], -sims[idx]))]
        return [(int(self.ids[j]), float(sims[j])) for j in idx]


def load(db, dbpath, get_meta):
    """A validated QuestionMatrix, or None. None is not an error."""
    vec_npy, ids_npy, meta_json = paths(dbpath)
    try:
        meta = json.loads(meta_json.read_text())
    except (OSError, ValueError):
        return None
    resolved = str(Path(os.path.realpath(os.path.expanduser(str(dbpath)))))
    if meta.get("db") != resolved or meta.get("dim") != CONTRACT["dim"]:
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
    return QuestionMatrix(mat, ids, meta, resolved)


def describe(db, dbpath, get_meta):
    vec_npy, _ids, meta_json = paths(dbpath)
    try:
        total = live_shape(db)[0]
    except Exception:
        return {"state": "absent", "detail": "qvec table not present"}
    if total == 0:
        return {"state": "absent", "detail": "no question vectors built yet"}
    if not meta_json.exists():
        return {"state": "table-only", "rows": total,
                "detail": "vectors stored, matrix not built"}
    m = load(db, dbpath, get_meta)
    if m is None:
        return {"state": "stale", "rows": total,
                "detail": "matrix superseded; rebuild with memory-vector-build --questions"}
    return {"state": "ok", "rows": m.rows,
            "bytes": vec_npy.stat().st_size if vec_npy.exists() else 0,
            "epoch": m.meta.get("epoch")}
