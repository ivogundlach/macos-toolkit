#!/usr/bin/env python3
"""Chunk + vector storage, and the rules that keep it honest.

Three problems this module exists to prevent, all of which are invisible when
they happen and expensive when discovered late:

1. MIXED-MODEL VECTORS. If the embedding model, its pooling, its prefixes, or the
   chunking parameters ever change, vectors written before and after are not
   comparable — and nothing errors. Every write records a fingerprint; readers
   refuse the vector arm when it does not match, and fall back to keyword search
   until a rebuild happens.

2. ORPHANED ROWS. A file edited from 10 chunks down to 3 leaves 7 stale chunks
   that still answer queries, quoting text the file no longer contains. Worse for
   vectors, where an orphan is a perfectly valid neighbour. Every file's chunks
   are replaced atomically: vectors first (they reference chunk rowids), then
   chunks, then the new rows, all inside one transaction.

3. HARD DEPENDENCE ON AN EXTENSION. sqlite-vec is a loadable extension; a Python
   or SQLite upgrade can stop it loading. Nothing here treats that as fatal —
   `open_db` reports whether vectors are available and the caller degrades.
"""
import os, sqlite3, time
from pathlib import Path

SCHEMA_VERSION = 1

CHUNKS_DDL = """
CREATE VIRTUAL TABLE chunks USING fts5(
    heading, body, path,
    root_tag UNINDEXED, rel_path UNINDEXED, ordinal UNINDEXED,
    abs_path UNINDEXED, file_hash UNINDEXED, indexed_at UNINDEXED,
    tokenize='unicode61')
"""
CHUNK_COLS = ("heading", "body", "path", "root_tag", "rel_path", "ordinal",
              "abs_path", "file_hash", "indexed_at")
META_DDL = "CREATE TABLE IF NOT EXISTS index_meta(key TEXT PRIMARY KEY, value TEXT)"


def load_vec(db):
    """Try to load sqlite-vec. Returns True/False — never raises.

    Deliberately soft. The vector arm is an enhancement over a keyword search that
    already works; losing it must degrade quality, not availability.
    """
    try:
        import sqlite_vec
        db.enable_load_extension(True)
        sqlite_vec.load(db)
        db.enable_load_extension(False)
        return True
    except Exception:
        try:
            db.enable_load_extension(False)
        except Exception:
            pass
        return False


def open_db(path, write=False):
    """(connection, vec_available). Creates the schema on first write."""
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(path), timeout=60, isolation_level=None)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=60000")
    vec = load_vec(db)
    if write:
        db.execute(META_DDL)
        if not _table_exists(db, "chunks"):
            db.execute(CHUNKS_DDL)
        if vec and not _table_exists(db, "vec_chunks"):
            from embedder import CONTRACT
            db.execute("CREATE VIRTUAL TABLE vec_chunks USING vec0("
                       f"chunk_id INTEGER PRIMARY KEY, embedding float[{CONTRACT['dim']}])")
    return db, vec


def _table_exists(db, name):
    return db.execute("SELECT 1 FROM sqlite_master WHERE name=?", (name,)).fetchone() is not None


def get_meta(db, key, default=None):
    try:
        r = db.execute("SELECT value FROM index_meta WHERE key=?", (key,)).fetchone()
    except sqlite3.DatabaseError:
        return default
    return r[0] if r else default


def set_meta(db, key, value):
    db.execute(META_DDL)
    db.execute("INSERT INTO index_meta(key,value) VALUES(?,?) "
               "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))


VECTOR_EPOCH = "vector_epoch"


def bump_vector_epoch(db):
    """Mark the vector table as changed. MUST be called by every writer.

    The derived matrix in vector_matrix.py is validated against this counter. The
    embedding fingerprint cannot serve that purpose: an incremental `--only` build
    adds and removes vectors without changing the model contract at all, so a
    fingerprint check would wave through a matrix that is missing everything
    indexed since it was written -- a silent recall hole rather than an error.
    Bumped inside the caller's transaction boundary so a rolled-back write cannot
    leave the counter ahead of the data.
    """
    try:
        cur = int(get_meta(db, VECTOR_EPOCH, "0") or 0)
    except (TypeError, ValueError):
        cur = 0
    set_meta(db, VECTOR_EPOCH, cur + 1)
    return cur + 1


def compatibility(db):
    """('ok'|'absent'|'mismatch', detail) for the vector arm.

    'mismatch' is the important one: it means vectors exist but were written by a
    different model or chunker, so using them would silently rank noise. Callers
    must treat it exactly like 'absent' for querying, and as a REBUILD signal for
    health checks.
    """
    if not _table_exists(db, "chunks"):
        return "absent", "no chunks table"
    from embedder import fingerprint
    want = fingerprint()
    have = get_meta(db, "embed_fingerprint")
    if have is None:
        return "absent", "no vectors written yet"
    if have != want:
        return "mismatch", f"index built with {have}, code expects {want}"
    if get_meta(db, "chunk_schema_version") != str(SCHEMA_VERSION):
        return "mismatch", "chunk schema version differs"
    return "ok", have


def replace_file(db, root_tag, rel_path, abs_path, file_hash, chunks, vectors=None):
    """Atomically swap one file's chunks (and vectors). Returns rows written.

    vectors is None when embeddings are unavailable — the chunks are still written,
    so keyword search over full (untruncated) text keeps working and only the
    vector arm is missing. Decoupling these is deliberate: an outage in one
    subsystem must not stop the other from indexing.
    """
    db.execute("BEGIN IMMEDIATE")
    try:
        old = [r[0] for r in db.execute(
            "SELECT rowid FROM chunks WHERE root_tag=? AND rel_path=?", (root_tag, rel_path))]
        if old and _table_exists(db, "vec_chunks"):
            db.executemany("DELETE FROM vec_chunks WHERE chunk_id=?", [(r,) for r in old])
        db.execute("DELETE FROM chunks WHERE root_tag=? AND rel_path=?", (root_tag, rel_path))
        now = str(int(time.time()))
        placeholders = ",".join("?" * len(CHUNK_COLS))
        for i, c in enumerate(chunks):
            cur = db.execute(
                f"INSERT INTO chunks({','.join(CHUNK_COLS)}) VALUES({placeholders})",
                (c["heading"], c["text"], c["path_tokens"], root_tag, rel_path,
                 c["ordinal"], abs_path, file_hash, now))
            if vectors is not None and _table_exists(db, "vec_chunks"):
                db.execute("INSERT INTO vec_chunks(chunk_id, embedding) VALUES(?,?)",
                           (cur.lastrowid, vectors[i].tobytes()))
        if vectors is not None:
            bump_vector_epoch(db)
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return len(chunks)


def delete_file(db, root_tag, rel_path):
    """Remove a file's chunks and vectors together. Used by the stale prune."""
    db.execute("BEGIN IMMEDIATE")
    try:
        old = [r[0] for r in db.execute(
            "SELECT rowid FROM chunks WHERE root_tag=? AND rel_path=?", (root_tag, rel_path))]
        if old and _table_exists(db, "vec_chunks"):
            db.executemany("DELETE FROM vec_chunks WHERE chunk_id=?", [(r,) for r in old])
        db.execute("DELETE FROM chunks WHERE root_tag=? AND rel_path=?", (root_tag, rel_path))
        if old:
            bump_vector_epoch(db)
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return len(old)


def orphan_report(db):
    """Vectors with no chunk, and prose chunks with no vector.

    A dangling vector is the dangerous direction: it is still a valid nearest
    neighbour and will surface content that no longer exists on disk. Reported by
    the weekly health check rather than assumed impossible.

    Code chunks are counted SEPARATELY and are not a defect. Under
    CONTRACT["vector_scope"] == "prose" they are stored but never embedded, so a
    plain "chunks without vectors" number is expected to be enormous and would be
    a health check that fires forever and therefore means nothing. Only a PROSE
    chunk missing its vector is a real coverage gap.
    """
    if not _table_exists(db, "vec_chunks") or not _table_exists(db, "chunks"):
        return {"vec_orphans": 0, "prose_without_vec": 0, "code_unembedded": 0,
                "checked": False}
    from file_eligibility import is_code
    vec_ids = {r[0] for r in db.execute("SELECT chunk_id FROM vec_chunks")}
    prose_missing = code_missing = 0
    chunk_ids = set()
    for rowid, rel in db.execute("SELECT rowid, rel_path FROM chunks"):
        chunk_ids.add(rowid)
        if rowid in vec_ids:
            continue
        if is_code(rel):
            code_missing += 1
        else:
            prose_missing += 1
    return {"vec_orphans": len(vec_ids - chunk_ids),
            "prose_without_vec": prose_missing,
            "code_unembedded": code_missing,
            "checked": True}
