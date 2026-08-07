#!/usr/bin/env python3
"""semantic-agy-build — build a meaning-based search index.

agy (Gemini Flash Low) reads each file once and emits a
compact semantic record (summary / topics / entities / questions-it-answers); the
record + raw text land in a global SQLite FTS5 table. Query time
(memory-semantic-query) is then pure local BM25 — no model, no network, offline.
No Ollama, no embeddings anywhere.

  usage: semantic-agy-build.py <root>
  env:   SEMANTIC_DB                  (default ~/.memory/semantic-index.sqlite)
         MEMORY_SEMANTIC_AGY_MODEL    (default "Gemini 3.5 Flash (Low)")
         SEMANTIC_CHUNK_SIZE          (default 8 files per agy call)
         SEMANTIC_MAX_FILE_CHARS      (default 6000 chars sent to agy per file)
  exit:  0 = clean; 1 = one or more chunks failed (already-indexed files are kept —
         failures are non-destructive, the hash cache re-attempts them next run).

Stdlib only (+ the `agy` CLI).
"""
import sys, os, re, json, sqlite3, subprocess, hashlib, time
from pathlib import Path

from index_scope import load_root_excludes
# Eligibility (which files exist as far as the index is concerned) is shared with
# the chunk/vector pass. See file_eligibility.py for why it must not be duplicated.
from file_eligibility import (CODE_EXTS, DOC_EXTS, EXTS, iter_files as _iter_files,
                              redact_secrets,
                              is_code as _is_code, path_tokens, read_text)

ROOT = Path(sys.argv[1]).expanduser().resolve() if len(sys.argv) > 1 else None
if not ROOT or not ROOT.is_dir():
    sys.stderr.write("semantic-agy-build: usage: semantic-agy-build.py <root>\n")
    raise SystemExit(2)

DB_PATH = Path(os.environ.get("SEMANTIC_DB", str(Path.home() / ".memory/semantic-index.sqlite"))).expanduser()
MODEL = os.environ.get("MEMORY_SEMANTIC_AGY_MODEL", "Gemini 3.5 Flash (Low)")
CHUNK_SIZE = int(os.environ.get("SEMANTIC_CHUNK_SIZE", "8"))
MAX_FILE_CHARS = int(os.environ.get("SEMANTIC_MAX_FILE_CHARS", "6000"))
# Hard cap so no single root (e.g. an accidental /opt/homebrew) can grind the
# weekly run for hours. Files beyond the cap (sorted) are skipped with a log line.
MAX_FILES_PER_ROOT = int(os.environ.get("SEMANTIC_MAX_FILES_PER_ROOT", "15000"))
MAX_AGY_FILES_PER_ROOT = int(os.environ.get("SEMANTIC_MAX_AGY_FILES_PER_ROOT", "250"))
ALLOW_LARGE_RUN = os.environ.get("MEMORY_SEMANTIC_ALLOW_LARGE_RUN") == "1"
DRY_RUN = os.environ.get("MEMORY_SEMANTIC_DRY_RUN") == "1"
ROOT_TAG = os.environ.get("SEMANTIC_ROOT_TAG", ROOT.name)
ROOT_EXCLUDES = load_root_excludes(ROOT)

# Code files are enriched LOCALLY (identifiers + leading comment), never sent to
# agy — code is found by its names, which BM25 already matches on the raw text, so
# the expensive LLM is reserved for prose/config where vocabulary-bridging matters.
# Everything in EXTS but NOT in CODE_EXTS (md/txt/json/yaml/toml/html/plist/…) is
# treated as prose and agy-enriched. Both sets live in file_eligibility.
NAME_PATTERNS = [
    r'^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)',                       # python/ruby
    r'^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$]\w*)',
    r'^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$]\w*)',
    r'^\s*(?:pub\s+)?(?:async\s+)?fn\s+([A-Za-z_]\w*)',             # rust
    r'^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)',                  # go/swift
    r'^\s*(?:export\s+)?(?:type|interface|struct|enum|trait|protocol|module)\s+([A-Za-z_$]\w*)',
    r'^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$]\w*)\s*=',
    r'^\s*([A-Za-z_]\w*)\s*\(\)\s*\{',                              # shell function
    r'^\s*function\s+([A-Za-z_]\w*)',
    r'(?i:create)\s+(?i:table|view|function|procedure|index|trigger)\s+(?i:if\s+not\s+exists\s+)?["`]?([A-Za-z_]\w*)',
]
NAME_RE = [re.compile(p, re.MULTILINE) for p in NAME_PATTERNS]
COMMENT_RE = re.compile(r'^\s*(?:#|//|--|;|/\*|\*|"""|\'\'\'|<!--)\s*(.+?)\s*(?:\*/|"""|\'\'\'|-->)?\s*$')
COMMENT_STARTS = ("#", "//", "--", ";", "/*", "*", '"""', "'''", "<!--")

# Bump PROMPT_VERSION whenever EXTRACT_PROMPT changes in a way that should produce
# different records. It is mixed into the cache key, so a bump re-enriches every
# prose file on the next build instead of silently serving records written by an
# older prompt. (Before this existed, the cache keyed on file content alone: the
# prompt could improve and nothing would ever be rewritten.)
PROMPT_VERSION = 2

# The `questions` column carries the heaviest bm25 weight after `summary`, and it
# is the only place the document's vocabulary can be made to look like the user's.
# v1 asked for "questions this file would answer" and got ~3, phrased in the
# document's own words — so a note saying "file LINKS must be relative" could not
# be reached by "how do I format file PATHS". v2 asks for breadth and for the
# asker's vocabulary, which is the entire point of paying an LLM at index time.
EXTRACT_PROMPT = (
    "You are building a SEMANTIC SEARCH index over a folder. For EACH file below, "
    "produce one JSON object so the file can later be found by MEANING, not just by "
    "keyword. Output a single JSON array, one object per file, each with EXACTLY "
    "these keys:\n"
    '  "path":      the exact path label shown after "FILE:" for that file\n'
    '  "summary":   1-2 sentences on what the file is and does\n'
    '  "topics":    array of short topic/concept tags, PLUS common synonyms and\n'
    "               alternative words for the same concepts (e.g. a file about\n"
    '               "links" should also carry "paths", "urls", "references")\n'
    '  "entities":  array of named things (functions, tools, commands, configs, people)\n'
    '  "questions": array of 6-10 DIVERSE natural-language questions this file\n'
    "               answers, written the way a person searching later would type\n"
    "               them, NOT in the file's own wording. Deliberately vary the\n"
    "               vocabulary between questions. Include, where they apply:\n"
    "                 - a plain 'how do I ...' / 'where is ...' phrasing\n"
    "                 - a SYMPTOM phrasing describing the problem being hit,\n"
    "                   with no tool or file name in it\n"
    "                 - a phrasing using everyday synonyms instead of the\n"
    "                   technical term the file uses\n"
    "                 - a phrasing naming the concrete tool, app, or command\n"
    "The questions are the search surface: if a reasonable person could ask it and "
    "this file is the answer, it belongs there.\n"
    "Cover every file. Return ONLY the JSON array — no preface, no explanation, no "
    "markdown code fences.\n\n"
)


SKIPS = {}

# Enrichment version, mixed into the cache key so a record is rebuilt when the
# LOGIC that produced it changes, not only when the file does. Prose records come
# from EXTRACT_PROMPT (PROMPT_VERSION); code records come from code_record()
# (CODE_VERSION). Without this a prompt improvement is invisible to every file
# that has not been edited since.
CODE_VERSION = 1

# Code files used to get NO agy pass at all: a leading comment, a list of
# identifiers, and an empty `questions` column. That made 696 of 2583 documents
# reachable only by a ~93-character summary and their own symbol names, so a file
# was findable by what it is CALLED and never by what it DOES -- and the gold set
# proves the cost: the case about concurrent runs of the school sync could not
# reach lock.py, because nothing in that record said the words the asker used.
# (Deliberately paraphrased. Writing a gold question verbatim in an indexed file
# makes the eval score THIS comment instead of the answer -- the benchmark then
# measures its own paperwork; see memory-retrieval-eval, which now warns about it
# because this exact line tripped it.)
# Identifiers are still extracted locally (deterministic, complete, and
# exactly the signal an LLM paraphrases away) and merged with the agy record, so
# this ADDS a meaning layer rather than replacing a working one.
CODE_PROMPT_VERSION = 1
CODE_EXTRACT_PROMPT = (
    "You are building a SEMANTIC SEARCH index over a folder of SOURCE CODE and "
    "configuration. For EACH file below, produce one JSON object describing what "
    "the code DOES and WHY someone would look for it -- never a line-by-line "
    "restatement of the code. Output a single JSON array, one object per file, "
    "each with EXACTLY these keys:\n"
    '  "path":      the exact path label shown after "FILE:" for that file\n'
    '  "summary":   1-2 sentences on what this file is responsible for, in plain\n'
    "               language a non-programmer could follow. Name the behaviour, "
    "not the syntax.\n"
    '  "topics":    array of short concept tags for the PROBLEM this code solves\n'
    "               (e.g. \"mutual exclusion\", \"retry\", \"rate limiting\"), plus\n"
    "               everyday synonyms for each\n"
    '  "entities":  array of the tools, commands, files, services, env vars and\n'
    "               APIs this file actually touches\n"
    '  "questions": array of 6-10 DIVERSE natural-language questions this file is\n'
    "               the answer to, written the way someone would type them months\n"
    "               later having FORGOTTEN the filename. Vary the vocabulary.\n"
    "               Include, where they apply:\n"
    "                 - a BEHAVIOUR phrasing: 'what stops/prevents/handles ...'\n"
    "                 - a SYMPTOM phrasing describing the failure this code\n"
    "                   guards against, naming no file and no function\n"
    "                 - a 'where is ... implemented' / 'which script does ...'\n"
    "                 - a phrasing in everyday words instead of the technical term\n"
    "Never invent behaviour the file does not have. If a file is trivial or "
    "generated, say so plainly and give fewer questions.\n"
    "Cover every file. Return ONLY the JSON array — no preface, no explanation, no "
    "markdown code fences.\n\n"
)


def file_hash(text, kind="prose"):
    ver = (PROMPT_VERSION if kind == "prose"
           else f"{CODE_VERSION}.{CODE_PROMPT_VERSION}")
    key = f"{kind}:{ver}:".encode() + text.encode("utf-8", "ignore")
    return hashlib.sha256(key).hexdigest()[:16]


# ---- schema ----------------------------------------------------------------
# v2 adds an indexed `path` column and porter stemming. Both fix real misses:
#   path   — a file's own name is often the most on-topic sentence about it, and
#            it was UNINDEXED, so "a scan held its lock forever" could not reach
#            tool-status-scan-lock-starvation.md by name at all.
# The tokenizer stays unicode61. Porter stemming was tried and MEASURED WORSE
# (recall@1 50% -> 38% on the gold set): collapsing index/indexing/indexes into
# one stem flattens the IDF that separates a document about a term from one that
# merely mentions it. Inflection is handled query-side instead, by expanding a
# term into its own alternatives, which keeps the rare-term signal intact.
# Migration is INSERT..SELECT from the old table: enrichment is preserved and NO
# agy calls are made. A rebuild-from-scratch would re-enrich ~2400 files.
SCHEMA_VERSION = 3
_COLS = ("summary", "topics", "entities", "questions", "path", "raw",
         "root_tag", "rel_path", "abs_path", "file_hash", "indexed_at")
_DDL = ("USING fts5(summary, topics, entities, questions, path, raw,"
        "root_tag UNINDEXED, rel_path UNINDEXED, abs_path UNINDEXED,"
        "file_hash UNINDEXED, indexed_at UNINDEXED,"
        "tokenize='unicode61')")

def tokenizer_of(db):
    """Tokenizer recorded in the docs table DDL ('' when the table is absent)."""
    r = db.execute("SELECT sql FROM sqlite_master WHERE name='docs'").fetchone()
    return (r[0] if r else "") or ""


def schema_of(db):
    """Column names of the existing docs table, or None when it does not exist."""
    try:
        return [r[1] for r in db.execute("PRAGMA table_info(docs)")]
    except sqlite3.DatabaseError:
        return None


def connect(db_path):
    db_path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(db_path), timeout=60)
    # WAL + busy_timeout: a query (or another root's build) can run while this one
    # writes without "database is locked" errors.
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=60000")
    # Single self-contained FTS5 table: indexed text columns first (for weighted
    # bm25), metadata UNINDEXED last. rel_path+root_tag identify a file.
    cols = schema_of(db)
    if not cols:
        db.execute("CREATE VIRTUAL TABLE docs " + _DDL)
        db.commit()
        return db
    if "path" not in cols or "porter" in tokenizer_of(db):
        migrate_schema(db, cols)
    return db


def migrate_schema(db, cols):
    """Rewrite the docs table into the current schema, preserving every enriched row.

    Runs inside the build lock (memory-semantic-build holds it), so no writer can
    race. Readers keep the old table until the final rename commits.
    """
    print(f"semantic: migrating index to schema v{SCHEMA_VERSION} "
          "(path column, unicode61)", flush=True)
    has_path = "path" in cols
    db.execute("DROP TABLE IF EXISTS docs_next")
    db.execute("CREATE VIRTUAL TABLE docs_next " + _DDL)
    rows = db.execute(
        "SELECT summary, topics, entities, questions, raw, root_tag, rel_path, "
        "abs_path, file_hash, indexed_at FROM docs").fetchall()
    db.executemany(
        "INSERT INTO docs_next(" + ",".join(_COLS) + ") VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        [(s, t, e, q, path_tokens(rt, rp), raw, rt, rp, ap, fh, ia)
         for s, t, e, q, raw, rt, rp, ap, fh, ia in rows])
    db.execute("DROP TABLE docs")
    db.execute("ALTER TABLE docs_next RENAME TO docs")
    db.commit()
    print(f"semantic: migrated {len(rows)} row(s) to schema v{SCHEMA_VERSION}"
          + ("" if has_path else " (path column added)"), flush=True)


def parse_records(out):
    """Extract a JSON array of records from agy output, tolerating fences/preamble."""
    s = out.strip()
    if s.startswith("```"):
        s = re.sub(r"^```[a-zA-Z0-9]*\n?", "", s)
        s = re.sub(r"\n?```\s*$", "", s).strip()
    try:
        data = json.loads(s)
    except json.JSONDecodeError:
        a, b = s.find("["), s.rfind("]")
        if a == -1 or b == -1 or b <= a:
            raise
        data = json.loads(s[a:b + 1])
    if isinstance(data, dict):
        data = data.get("files") or data.get("records") or [data]
    return data if isinstance(data, list) else []


def agy_enrich(batch, prompt_header=EXTRACT_PROMPT):
    """batch: list of (rel_path, text). Returns {rel_path: record}. Raises on failure."""
    parts = [prompt_header]
    for rel, text in batch:
        # Last gate before anything leaves the machine. Every caller passes
        # through here, so a future enrichment path cannot bypass it by accident.
        clean = redact_secrets(text[:MAX_FILE_CHARS])
        parts.append(f"===== FILE: {rel} =====\n{clean}\n")
    prompt = "".join(parts).replace("\x00", "")
    env = os.environ.copy()
    env["BROWSER"] = "/usr/bin/false"
    proc = subprocess.run(
        ["agy", "--model", MODEL, "--dangerously-skip-permissions",
         "--print-timeout", "10m", "--print", prompt],
        capture_output=True, text=True, timeout=900,
        stdin=subprocess.DEVNULL, cwd="/tmp",
        env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"agy rc={proc.returncode}: {(proc.stderr or '')[-300:].strip()}")
    if not (proc.stdout or "").strip():
        raise RuntimeError("agy returned empty output")
    records = parse_records(proc.stdout)
    by_path = {}
    valid = {rel for rel, _ in batch}
    for r in records:
        if isinstance(r, dict) and r.get("path") in valid:
            by_path[r["path"]] = r
    return by_path


def as_text(v):
    if isinstance(v, list):
        return " ".join(str(x) for x in v)
    return str(v or "")


def upsert(db, rel, abspath, fhash, rec, raw):
    db.execute("DELETE FROM docs WHERE root_tag = ? AND rel_path = ?", (ROOT_TAG, rel))
    db.execute(
        "INSERT INTO docs(" + ",".join(_COLS) + ") VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (as_text(rec.get("summary")), as_text(rec.get("topics")),
         as_text(rec.get("entities")), as_text(rec.get("questions")),
         path_tokens(ROOT_TAG, rel),
         raw[:20000], ROOT_TAG, rel, abspath, fhash, str(int(time.time()))),
    )


def code_record(rel, raw):
    """Build a search record for a code file locally — no agy. Pulls top-level
    identifier names (the real search signal for code) + a leading comment."""
    lines = raw.splitlines()
    summary = ""
    for ln in lines[:30]:
        s = ln.strip()
        if not s or s.startswith("#!") or "coding:" in s or s.startswith("-*-"):
            continue
        m = COMMENT_RE.match(ln)
        if m and len(m.group(1)) > 8 and not m.group(1).startswith("-*-"):
            summary = m.group(1)[:200]
            break
        if not s.startswith(COMMENT_STARTS):  # real code began; stop scanning
            break
    names = []
    for rx in NAME_RE:
        for m in rx.finditer(raw):
            n = m.group(1)
            if n and n not in names:
                names.append(n)
        if len(names) >= 50:
            break
    ext = Path(rel).suffix.lower().lstrip(".")
    parts = [p for p in Path(rel).parent.parts if p not in (".", "")]
    if not summary:
        summary = f"{ext} source file ({Path(rel).name})"
    return {
        "summary": summary,
        "topics": " ".join(parts + [ext, "source", "code"]),
        "entities": " ".join(names[:50]),
        "questions": "",
    }


def main():
    db = connect(DB_PATH)
    # hash cache for this root: skip files whose content is unchanged since last build
    have = {}
    for rel, h in db.execute(
            "SELECT rel_path, file_hash FROM docs WHERE root_tag = ?", (ROOT_TAG,)):
        have[rel] = h

    # Collect paths first (cheap), apply the per-root cap, THEN read/hash — so a
    # pathological root bounds IO and agy cost instead of reading 100k files.
    SKIPS.clear()
    all_paths = sorted(_iter_files(ROOT, ROOT_EXCLUDES, SKIPS))
    paths = all_paths
    cap_note = ""
    capped = False
    if len(paths) > MAX_FILES_PER_ROOT:
        capped = True
        cap_note = (f" | CAPPED {len(paths)}->{MAX_FILES_PER_ROOT} "
                    "(raise SEMANTIC_MAX_FILES_PER_ROOT to index more)")
        paths = paths[:MAX_FILES_PER_ROOT]

    todo = []          # (rel, abspath, fhash, raw)
    eligible_rels = set()
    scanned = 0
    for p in paths:
        rel = str(p.relative_to(ROOT))
        # Preserve an existing record if document extraction is temporarily empty
        # or unavailable; stale means the eligible path itself disappeared.
        eligible_rels.add(rel)
        raw = read_text(p)
        if not raw.strip():
            continue
        scanned += 1
        fhash = file_hash(raw, "code" if _is_code(rel) else "prose")
        if have.get(rel) == fhash:
            continue
        todo.append((rel, str(p), fhash, raw))

    # Both arms go to agy now, with different prompts: prose gets a summary that
    # bridges vocabulary, code gets a behaviour description (see
    # CODE_EXTRACT_PROMPT) on top of the deterministic local identifier
    # extraction, which it merges with rather than replaces.
    prose_todo = [t for t in todo if not _is_code(t[0])]
    code_todo = [t for t in todo if _is_code(t[0])]

    chunks = [prose_todo[i:i + CHUNK_SIZE] for i in range(0, len(prose_todo), CHUNK_SIZE)]
    print(f"semantic[{ROOT_TAG}]: scanned {scanned} | cached {scanned - len(todo)} | "
          f"code/agy {len(code_todo)} | prose/agy {len(prose_todo)} in {len(chunks)} "
          f"chunk(s){cap_note} (model: {MODEL})", flush=True)

    # Never skip silently. A dropped file is indistinguishable from a file that was
    # never there, which is how a real capture sat unindexed with nothing to notice.
    if SKIPS:
        parts = ", ".join(f"{k} {len(v)}" for k, v in sorted(SKIPS.items()))
        print(f"  skipped[{ROOT_TAG}]: {parts}", flush=True)
        for reason in ("secret_name", "secret_name_nonprose", "unreadable"):
            for path in SKIPS.get(reason, [])[:10]:
                print(f"    {reason}: {path}", flush=True)

    # Counts BOTH arms: code files now cost agy calls too, and a guard that still
    # counted only prose would have quietly stopped bounding the bill the moment
    # code enrichment was added -- the cap would read 0 for a root of 300 scripts.
    if len(prose_todo) + len(code_todo) > MAX_AGY_FILES_PER_ROOT and not ALLOW_LARGE_RUN:
        print(f"BLOCKED[{ROOT_TAG}]: {len(prose_todo) + len(code_todo)} uncached files exceeds "
              f"SEMANTIC_MAX_AGY_FILES_PER_ROOT={MAX_AGY_FILES_PER_ROOT}; inspect scope "
              "or set MEMORY_SEMANTIC_ALLOW_LARGE_RUN=1 for a deliberate one-time build",
              flush=True)
        db.close()
        raise SystemExit(78)

    if DRY_RUN:
        stale = 0 if capped else len(set(have) - eligible_rels)
        print(f"DRY-RUN[{ROOT_TAG}]: would prune {stale} stale record(s); no writes or agy calls",
              flush=True)
        db.close()
        return

    # Prune rows whose files moved, were deleted, or are now excluded. Do not prune
    # when the hard file cap truncated the scan because unseen rows may still be valid.
    stale_rels = [] if capped else sorted(set(have) - eligible_rels)
    if stale_rels:
        db.executemany("DELETE FROM docs WHERE root_tag = ? AND rel_path = ?",
                       [(ROOT_TAG, rel) for rel in stale_rels])
        db.commit()

    # Code: agy for meaning, local extraction for identifiers, merged. The local
    # record is written FIRST for every file, so a failed or skipped agy chunk
    # leaves the old behaviour rather than an empty record -- enrichment that can
    # fail must degrade to the working system, never to a hole in the index.
    #
    # That first write is stamped with a `local:` prefixed hash, which can never
    # equal file_hash(), so the file stays a cache MISS until agy actually
    # succeeds on it. Stamping the real hash up front would have made fail-soft
    # silently permanent: eight local-bin files lost one chunk to a network blip
    # and would then have looked "cached" forever, unenriched, with nothing in
    # the index distinguishing them from files that were never meant to be
    # enriched. Degrading on failure is correct; REMEMBERING the degraded state
    # as if it were the finished one is not.
    indexed = 0
    for rel, abspath, fhash, raw in code_todo:
        upsert(db, rel, abspath, f"local:{fhash}", code_record(rel, raw), raw)
        indexed += 1
    if code_todo:
        db.commit()

    code_chunks = [code_todo[i:i + CHUNK_SIZE]
                   for i in range(0, len(code_todo), CHUNK_SIZE)]
    code_failed = 0
    for idx, chunk in enumerate(code_chunks, 1):
        try:
            recs = agy_enrich([(rel, raw) for rel, _ab, _h, raw in chunk],
                              prompt_header=CODE_EXTRACT_PROMPT)
        except Exception as e:
            code_failed += 1
            print(f"  code chunk {idx}/{len(code_chunks)} FAILED: {e}", flush=True)
            continue
        for rel, abspath, fhash, raw in chunk:
            rec = recs.get(rel)
            if not rec:
                continue                     # keep the local record already written
            local = code_record(rel, raw)
            # Identifiers are extracted deterministically and completely; an LLM
            # asked for "entities" returns a readable subset. Union both, local
            # first, so exact-symbol search never gets worse than it was.
            rec["entities"] = (local["entities"] + " " + as_text(rec.get("entities"))).strip()
            upsert(db, rel, abspath, fhash, rec, raw)
        db.commit()
    if code_chunks:
        print(f"semantic[{ROOT_TAG}]: code enriched "
              f"{len(code_chunks) - code_failed}/{len(code_chunks)} chunk(s)", flush=True)

    failed = 0
    for idx, chunk in enumerate(chunks, 1):
        batch = [(rel, raw) for rel, _ab, _h, raw in chunk]
        try:
            recs = agy_enrich(batch)
        except Exception as e:
            failed += 1
            print(f"  chunk {idx}/{len(chunks)} FAILED: {e}", flush=True)
            continue
        for rel, abspath, fhash, raw in chunk:
            rec = recs.get(rel)
            if not rec:
                # agy dropped this file from its array — leave any prior record intact
                continue
            upsert(db, rel, abspath, fhash, rec, raw)
            indexed += 1
        db.commit()
        print(f"  chunk {idx}/{len(chunks)}: +{len(recs)} files", flush=True)

    db.commit()
    total = db.execute("SELECT COUNT(*) FROM docs WHERE root_tag = ?", (ROOT_TAG,)).fetchone()[0]
    suffix = f" ({failed} chunk(s) FAILED)" if failed else ""
    # Say the degraded count out loud. It is self-healing (the `local:` hash
    # forces a retry next run), but a number that only ever appears in a log line
    # at the moment of failure cannot show that it has been stuck for a week.
    stuck = db.execute("SELECT COUNT(*) FROM docs WHERE root_tag = ? AND "
                       "file_hash LIKE 'local:%'", (ROOT_TAG,)).fetchone()[0]
    if stuck:
        suffix += f", {stuck} local-only (will retry)"
    print(f"RESULT[{ROOT_TAG}]: indexed {indexed} this run, pruned {len(stale_rels)}, "
          f"{total} total{suffix}", flush=True)
    db.close()
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
