#!/usr/bin/env python3
"""Reciprocal Rank Fusion over the retrieval arms.

Three arms answer the same question in different ways:

  A  docs      file-level BM25 over LLM-written summary/topics/entities/questions
  B  chunks    chunk-level BM25 over the raw text, untruncated
  C  vectors   chunk-level cosine KNN over local embeddings

RRF is used rather than score blending because the arms produce incomparable
numbers — FTS5 bm25 is an unbounded negative, cosine is [-1,1]. Normalizing them
against each other requires calibration that drifts silently as the corpus grows.
Ranks do not drift.

Two properties this module must guarantee, both load-bearing:

  FAIL-OPEN. Any arm can vanish (extension won't load, model missing, fingerprint
  mismatch after a model change) and search must still work. With arms B and C
  absent, `fuse` returns arm A's order EXACTLY — that is the rollback path, and
  it is asserted by a test rather than assumed.

  DETERMINISTIC. Same index and same query produce the same order, including
  ties. Ties break on the full path, never on dict or row order, so results do
  not shuffle between runs and an eval regression means a real change.
"""
import os

# All defaults below were swept on the 52-case gold set (2026-07-29), with every
# configuration ALSO scored on two deterministic halves split by a hash of the
# question. A setting was only accepted when both halves moved the same way —
# at 52 cases one case is 1.9%, so a two-case swing can otherwise be dressed up
# as a four-point win.
#
# Measured: baseline (enriched arm alone) r1 59.6% / r5 84.6%
#           final                          r1 73.1% / r5 90.4%
#
# k controls how much rank POSITION matters versus mere presence in an arm. At
# k=60 every rank in a 120-deep arm contributes within a factor of ~3, so fusion
# degenerates toward "how many arms found this file". k=40 sits in a wide plateau:
# 73.1%/90.4% is reproduced at k=30, 40 and 50 and at weights 0.15 and 0.2, which
# is what distinguishes a real effect from a lucky point.
RRF_K = float(os.environ.get("MEMORY_RRF_K", "40"))
W_DOCS = float(os.environ.get("MEMORY_RRF_W_DOCS", "1.0"))
# The chunk BM25 arm was MEASURED HARMFUL and is off. Raw untruncated text without
# enrichment matches on incidental vocabulary — mostly code and logs — and it cost
# recall@5 8 points (84.6% -> 76.9%) while adding ~2 at recall@1. The chunks table
# itself stays: it is what the vector arm searches, and it is what finally indexes
# the content past the old 20,000-character truncation. It is the keyword ARM over
# those chunks that does not earn its place, not the chunking.
W_CHUNKS = float(os.environ.get("MEMORY_RRF_W_CHUNKS", "0"))
# The vector arm is an ADVISOR, not a peer: the enriched arm already carries
# LLM-written questions and synonyms, which is a stronger semantic bridge than a
# 33M-parameter bi-encoder. Measured — at w=1.0 the vector arm OVERRIDES the
# enriched arm and recall drops (r1 63.5%); at w=0.2 it breaks ties and recall
# peaks. More weight is actively worse, which is the opposite of the intuition
# that a "smarter" arm deserves more say.
W_VEC = float(os.environ.get("MEMORY_RRF_W_VEC", "0.2"))

# Arm D: the SAME query vector matched against the agy-generated questions rather
# than against prose (question_index.py). It exists because the arms above all
# compare a question to a document -- lexically in A and B, and across the
# query/passage asymmetry in C -- while the enrichment pass has already written
# ~5 questions per document that can be compared to the query in one space.
# 0.0 disables the arm outright and reproduces the pre-arm ordering exactly,
# which is what makes the control free.
#
# Swept on the 112-case set, arm D on top of the shipped configuration:
#
#            r@1 / r@5
#   0.00      58 / 87   <- control, arm absent
#   0.20      61 / 87
#   0.30      61 / 87
#   0.35      62 / 88
#   0.40      62 / 88   <- default, middle of the plateau
#   0.45      61 / 88
#   0.50      60 / 87
#   0.70      59 / 87
#   1.00      58 / 85
#   1.50      56 / 80
#
# The same shape as W_VEC and for the same reason: this arm is an ADVISOR that
# breaks ties the enriched arm cannot, and at full weight it starts overriding
# an arm that knows more about the corpus than it does. Note the collapse is
# gradual on r@1 and sudden on r@5 past 1.0 -- by then the questions are choosing
# the result set, not refining it.
W_QVEC = float(os.environ.get("MEMORY_RRF_W_QVEC", "0.40"))
# How many questions to pull before collapsing them to documents. Each document
# owns ~5, and near-duplicate phrasings cluster, so the top-N questions can
# easily be one document five times -- this is fetched deep and then deduped by
# document, exactly like MAX_CHUNKS_PER_FILE does for the chunk arm.
QVEC_FANOUT = int(os.environ.get("MEMORY_QVEC_FANOUT", "6"))

# A single large file can produce hundreds of chunks. Without a per-file cap it
# would occupy most of a candidate window and starve every other document — the
# arm would look like it was working while quietly reducing diversity.
MAX_CHUNKS_PER_FILE = int(os.environ.get("MEMORY_FUSE_CHUNKS_PER_FILE", "3"))
ARM_DEPTH = int(os.environ.get("MEMORY_FUSE_ARM_DEPTH", "120"))

# Curated notes are written to be found; raw chat captures are transcript sludge
# that happens to contain the same words. A measured failure mode was a capture
# outranking the curated note that actually answers the question. This is a
# rank-space nudge applied AFTER fusion, not a filter — a capture that is the only
# answer still wins. It is NOT cosmetic: removing it while keeping everything else
# costs 11.6 points at recall@1 (73.1% -> 61.5%).
#
# 0.42 WAS AN ARTIFACT OF THE BENCHMARK, and this is the cautionary example.
# It was set on 2026-07-31 by a joint sweep that looked impeccable — a rise, a
# four-point plateau at 77/94, a collapse past it. What that sweep did not
# examine was what the 52-case gold set was MADE OF: 35 of its 52 targets were
# curated notes under root_tag "memory", i.e. the exact class this constant
# boosts, drawn from 2.6% of the corpus. The knob was scored almost entirely on
# the thing it promotes, so the curve measured the benchmark's composition, not
# the ranker's quality.
#
# Re-swept the same day against a widened 112-case set (31% curated notes, plus
# project wikis, skill bodies, raw captures and 21 ordinary source/artifact
# files), at CODE_PENALTY = 0.00:
#
#            r@1 / r@5
#   0.00      51 / 81
#   0.05      52 / 82
#   0.10      52 / 83
#   0.15      51 / 83   <- default
#   0.20      51 / 84
#   0.30      50 / 82
#   0.42      49 / 79   <- the value fitted on the narrow set
#   0.60      47 / 76
#
# Same shape, different location: the plateau is 0.10-0.20 and 0.42 is off the
# far side of it. 0.15 is its middle, measured rather than interpolated. Nothing
# about the ranker changed between the two sweeps — only which questions it was
# asked. A KNOB TUNED ON A NARROW BENCHMARK IS FITTED TO THE BENCHMARK; widen the
# question set before trusting a knob that boosts a document class.
#
# Run-to-run noise here is ±1 case (~0.9 points): the vector arm has a 1.5s
# daemon deadline and occasionally drops out under load. Differences of one case
# between neighbouring cells are not signal, which is why the plateau centre is
# taken rather than the single best cell.
SOURCE_PRIOR = float(os.environ.get("MEMORY_FUSE_SOURCE_PRIOR", "0.15"))
# THE single most important design decision here, recorded where the numbers are:
# with code, logs and config in the vector table the arm made search WORSE than
# having no vector arm at all (r1 46.2% against a 59.6% baseline). Two thirds of
# this corpus is source, and a generic sentence embedder happily ranks a Swift
# file that is "topically about locking" above the note that answers the question.
# Embedding prose only is worth +13.5 points at recall@1.
#
# That scope is enforced at BUILD time (embedder.CONTRACT["vector_scope"]) and is
# part of the fingerprint, so the table and the searcher cannot disagree — an
# index built under a different scope reads as a mismatch and the arm goes dark
# instead of half-answering. There is deliberately no query-time knob for it.
CURATED_TAGS = {"memory"}
# DO NOT "generalize" this to a path rule. It looks like an oversight that the
# raw/ demotion is keyed on root_tag and so only ever fires for the global
# ~/.memory, leaving 341 raw captures under project roots undemoted. Making it
# path-based was MEASURED and cost 7.7 points at recall@1 (69.2% -> 61.5%) and
# 3.9 at recall@5, both halves down. The asymmetry is real: the global memory has
# a curated layer written on top of its captures, so raw there is redundant
# sludge -- project memories usually have no such layer, so the raw capture IS
# the canonical answer, and two gold cases expect exactly that.


# Source files got agy behaviour-descriptions on 2026-07-30, which made them
# genuinely findable and also made them competitors. A small demotion buys the
# best recall@5 this system has measured. Swept against the 52-case gold set,
# every value confirmed at a neighbour:
#
#   0.0        r1 71%  r5 92%   (48 of 52 findable in the top five)
#   0.05-0.08  r1 71%  r5 94%   <- default sits here
#   0.10-0.12  r1 73%  r5 92%
#   0.15-0.30  r1 75%  r5 90%
#   0.35-0.95  r1 73%  r5 90%
#
# READ THAT AS A TRADE CURVE, NOT A PEAK. Raising the penalty moves roughly one
# case from "in the top five" to "at rank one" per 0.05, and 2% is ONE case out
# of 52 -- do not tune this against a single case. The low end is chosen because
# of how the result is consumed: an agent reads the returned list, so being
# findable at all beats being first, and 94% is the highest r5 ever measured
# here. It is deliberately NOT set to the r1-maximising 0.20: at that value the
# two cases that fall out of the top five are ones where a CODE FILE IS THE
# CORRECT ANSWER (School/sync/uahsync/lock.py, NutrientTracker/tools/build_usda_db.py),
# which is the penalty doing real damage rather than filtering noise.
#
# Near-total demotion (0.95) still scores 73/90, so enriched code outranking
# prose was NEVER the main cost of that day's corpus change -- see
# memory-retrieval-eval for what actually moved.
#
# RE-SWEPT 2026-07-31 after the corpus grew again (the eval's own notes are IN the
# corpus, so writing about retrieval changes retrieval). The curve flattened:
#
#   0.00-0.06  r1 71%  r5 92%
#   0.10-0.12  r1 73%  r5 92%   <- default moved here
#   0.15-0.20  r1 73%  r5 90%
#
# The r@5 advantage that justified the low end is GONE -- 92% across the whole
# lower range now -- so at equal r@5 the higher-r@1 plateau wins, and the reason
# for the old value expired rather than being disproved. Honest about size: 71->73
# is ONE case out of 52, exactly the margin this comment warns not to chase. It is
# taken only because 0.10 and 0.12 agree (a plateau, not a spike) and nothing
# measurable is given up. The four r@5 misses are IDENTICAL at 0.0 and at 0.11,
# including the one where a code file is the right answer -- so the penalty is not
# what puts them there, and lowering it does not bring them back.
#
# DEFAULTED OFF 2026-07-31 on the widened 112-case gold set. Every sweep above
# ran against a set with TWO code-file targets in it; the widened set has 21, and
# the trade curve stops being a trade:
#
#            r@1 / r@5      at SOURCE_PRIOR = 0.10
#   0.00      52 / 83   <- default
#   0.06      51 / 83
#   0.11      52 / 81   <- previous default
#   0.20      51 / 72
#   0.30      51 / 71
#
# There is no r@1 gain left to buy and r@5 falls off a cliff above 0.11, because
# the cases that fall out of the top five are the ones where a code file IS the
# answer -- the failure this comment predicted, now the dominant effect rather
# than a corner case. The mechanism is kept (env-tunable, and the `and` in fuse()
# short-circuits at 0.0) so it can be re-swept, not deleted on one measurement.
CODE_PENALTY = float(os.environ.get("MEMORY_FUSE_CODE_PENALTY", "0.00"))
# Suffixes are inlined instead of imported from file_eligibility because this is
# the query hot path and that module pulls subprocess/shutil for document
# extraction -- several ms on an 88ms query, to answer a question about a string.
_CODE_SUFFIXES = (
    ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".sh", ".bash", ".zsh",
    ".rb", ".go", ".rs", ".swift", ".java", ".kt", ".c", ".h", ".cpp", ".hpp",
    ".cc", ".m", ".mm", ".sql", ".lua", ".pl", ".gradle", ".vue", ".svelte",
    ".css", ".scss", ".applescript",
)


def _is_code_path(rel_path):
    return rel_path.endswith(_CODE_SUFFIXES) or "." not in rel_path.rsplit("/", 1)[-1]


def _is_curated(root_tag, rel_path):
    if root_tag in CURATED_TAGS:
        return True
    return root_tag == ".memory" and not (
        rel_path.startswith("raw/") or "/raw/chat/" in rel_path)


def _cap_per_file(rows):
    """Keep at most MAX_CHUNKS_PER_FILE rows per file, preserving arm order."""
    seen, out = {}, []
    for r in rows:
        key = (r[0], r[1])
        n = seen.get(key, 0)
        if n >= MAX_CHUNKS_PER_FILE:
            continue
        seen[key] = n + 1
        out.append(r)
    return out


def chunk_bm25(db, match, root=None, depth=ARM_DEPTH):
    """Arm B. Returns [(root_tag, rel_path, snippet)] best-first, or [] if absent."""
    try:
        sql = ("SELECT root_tag, rel_path, snippet(chunks, 1, '[', ']', ' … ', 12), "
               "bm25(chunks, 3.0, 1.0, 1.5) AS score FROM chunks WHERE chunks MATCH ?")
        params = [match]
        if root:
            sql += " AND root_tag = ?"
            params.append(root)
        sql += " ORDER BY score LIMIT ?"
        params.append(depth * MAX_CHUNKS_PER_FILE)
        rows = db.execute(sql, params).fetchall()
    except Exception:
        return []
    return _cap_per_file([(r[0], r[1], r[2]) for r in rows])[:depth]


def vector_knn(db, query_vec, root=None, depth=ARM_DEPTH, matrix=None):
    """Arm C. Returns [(root_tag, rel_path, body_prefix)] nearest-first.

    RAISES on a broken arm rather than returning []. That distinction is the whole
    point: this function returned [] on `no such module: vec0` for an entire
    measurement run, and because "arm is dead" and "arm found nothing" look
    identical at the call site, a sweep was recorded as evidence about vector
    search when the vector arm had never executed. An empty list means no
    neighbours; an exception means the arm is broken. The caller decides.

    The root filter is applied AFTER the KNN rather than inside it: sqlite-vec's
    k is a hard limit on rows returned, so filtering inside the vector search
    would silently return far fewer than `depth` candidates for a narrow root.
    """
    if query_vec is None:
        return []
    k = depth * MAX_CHUNKS_PER_FILE * (4 if root else 1)
    # The matrix is an optional accelerator for the SAME exact search, ~8x faster
    # and the reason this arm's cost stops mattering as the corpus grows (see
    # vector_matrix.py). It is passed in by a caller that holds it warm; when it
    # is absent, superseded, or belongs to another database, `matrix` is None and
    # the authoritative vec0 scan below answers instead. Identical results, only
    # slower -- which is why this fallback is allowed to be silent.
    hits = None
    if matrix is not None:
        try:
            hits = matrix.knn(query_vec, k)
        except Exception:
            hits = None                     # never let the fast path break the arm
    if hits is not None:
        if not hits:
            return []
        # One statement rather than a per-hit lookup: at k=1440 (a root-scoped
        # rerank pool) sixty round trips through sqlite would give back the
        # milliseconds the matrix just saved.
        order = {cid: i for i, (cid, _d) in enumerate(hits)}
        ph = ",".join("?" * len(order))
        rows = db.execute(
            f"SELECT rowid, root_tag, rel_path, substr(body,1,240) FROM chunks "
            f"WHERE rowid IN ({ph})", list(order)).fetchall()
        rows.sort(key=lambda r: order[r[0]])
        rows = [(r[1], r[2], r[3]) for r in rows]
    else:
        raw = db.execute(
            "SELECT c.root_tag, c.rel_path, substr(c.body,1,240), v.distance "
            "FROM (SELECT chunk_id, distance FROM vec_chunks "
            "      WHERE embedding MATCH ? AND k = ?) v "
            "JOIN chunks c ON c.rowid = v.chunk_id ORDER BY v.distance",
            (query_vec.tobytes(), k)).fetchall()
        rows = [(r[0], r[1], r[2]) for r in raw]
    if root:
        rows = [r for r in rows if r[0] == root]
    return _cap_per_file(rows)[:depth]


def question_knn(db, query_vec, root=None, depth=ARM_DEPTH, matrix=None):
    """Arm D. Returns [(root_tag, rel_path, question)] nearest-first, one per file.

    Same contract as vector_knn and for the same reason: RAISES when the arm is
    broken and returns [] only when there genuinely are no neighbours. An arm
    that answers [] while dead is indistinguishable from one that works, and
    that ambiguity has already cost this codebase a whole measurement run.

    `matrix` is the accelerator. When it is absent or superseded the qvec TABLE
    is read directly — slower, identical results — so the arm keeps answering
    from the authoritative store rather than going dark on a stale cache.
    """
    if query_vec is None:
        return []
    k = depth * QVEC_FANOUT * (4 if root else 1)
    hits = None
    if matrix is not None:
        try:
            hits = matrix.knn(query_vec, k)
        except Exception:
            hits = None                     # never let the fast path break the arm
    if hits is not None:
        if not hits:
            return []
        order = {qid: i for i, (qid, _s) in enumerate(hits)}
        ph = ",".join("?" * len(order))
        raw = db.execute(
            f"SELECT qid, root_tag, rel_path, question FROM qvec "
            f"WHERE qid IN ({ph})", list(order)).fetchall()
        raw.sort(key=lambda r: order[r[0]])
        rows = [(r[1], r[2], r[3]) for r in raw]
    else:
        import numpy as np
        raw = db.execute("SELECT root_tag, rel_path, question, embedding "
                         "FROM qvec").fetchall()
        if not raw:
            return []
        q = np.asarray(query_vec, dtype=np.float32).reshape(-1)
        mat = np.frombuffer(b"".join(r[3] for r in raw), dtype=np.float32)
        mat = mat.reshape(len(raw), -1)
        if mat.shape[1] != q.size:
            raise ValueError(f"query dim {q.size} != qvec dim {mat.shape[1]}")
        sims = mat @ q
        idx = np.argsort(-sims)[:k]
        rows = [(raw[i][0], raw[i][1], raw[i][2]) for i in idx]
    if root:
        rows = [r for r in rows if r[0] == root]
    # One row per file, at its best-matching question. Without this a document
    # whose five questions all paraphrase each other would occupy five of the
    # slots the arm has to spend.
    seen, out = set(), []
    for r in rows:
        key = (r[0], r[1])
        if key in seen:
            continue
        seen.add(key)
        out.append(r)
        if len(out) >= depth:
            break
    return out


def fuse(doc_rows, chunk_rows, vec_rows, top, qvec_rows=None):
    """Fuse ranked arms into a file-level ordering.

    doc_rows:   [(root_tag, rel_path, summary, score, snippet)] — arm A, best-first
    chunk_rows: [(root_tag, rel_path, snippet)]                 — arm B, best-first
    vec_rows:   [(root_tag, rel_path, body_prefix)]             — arm C, best-first
    qvec_rows:  [(root_tag, rel_path, question)]                — arm D, best-first

    An absent arm contributes nothing; it is NOT renormalized away, so adding an
    arm can only add evidence. With B and C empty the output order is arm A's own.
    """
    if not chunk_rows and not vec_rows and not qvec_rows:
        return [(r, None, None) for r in doc_rows[:top]]

    scores, best_doc, best_snip = {}, {}, {}

    def add(rows, weight, snippet_index):
        seen_files = set()
        rank = 0
        for r in rows:
            key = (r[0], r[1])
            if key in seen_files:
                continue                      # a file scores once, at its best rank
            seen_files.add(key)
            rank += 1
            scores[key] = scores.get(key, 0.0) + weight / (RRF_K + rank)
            if snippet_index is not None and key not in best_snip and len(r) > snippet_index:
                best_snip[key] = r[snippet_index]

    for r in doc_rows:
        best_doc[(r[0], r[1])] = r
    add(doc_rows, W_DOCS, None)
    add(chunk_rows, W_CHUNKS, 2)
    add(vec_rows, W_VEC, 2)
    add(qvec_rows or [], W_QVEC, 2)

    for key in scores:
        if _is_curated(*key):
            scores[key] *= (1.0 + SOURCE_PRIOR)
        elif CODE_PENALTY and _is_code_path(key[1]):
            scores[key] *= (1.0 - CODE_PENALTY)

    # Deterministic: score descending, then path ascending. Never dict order.
    order = sorted(scores, key=lambda k: (-scores[k], k[0], k[1]))[:top]
    out = []
    for key in order:
        d = best_doc.get(key)
        if d is None:
            # Found only by a chunk/vector arm — no enriched row exists for it.
            d = (key[0], key[1], "", None, best_snip.get(key, ""))
        out.append((d, best_snip.get(key), scores[key]))
    return out


# ---- cross-encoder reranking -------------------------------------------------
# The measured failure mode was never "cannot find it" — it was near-misses: the
# right file sat at rank 2 or 3 behind a topically similar neighbour. A bi-encoder
# scores query and passage separately and can't tell those apart; a cross-encoder
# reads both together and can.
#
# It REORDERS, it does not replace. Pure cross-encoder order was measured and is
# WORSE than no reranker at all (r1 69.2% -> 61.5%): the model knows topical
# relevance but nothing about this corpus's structure — which of five notes on the
# same subsystem is the canonical one — and it traded 12 correct rank-1s for 9
# near-miss fixes. Fused by RRF over the two orderings it takes the wins without
# the losses: r1 69.2% -> 76.9%, r5 88.5% -> 92.3%, both hash-split halves up, and
# not one gold case regressed. RRF is used rather than a weighted sum because the
# two scales don't commute — CE logits run about -11..+11 against fusion scores
# near 0.02, so no fixed alpha transfers.
RERANK = os.environ.get("MEMORY_RERANK", "1") != "0"
# DEPTH AND WEIGHT RE-DERIVED 2026-07-31 on the widened 112-case gold set.
# The old comment here read "depth 10 and 20 score identically" -- true on the
# narrow 52-case set it was measured against, and false. Diagnosing the widened
# set's misses at depth 60 showed 16 of 20 were RETRIEVED but ranked 6-44, i.e.
# an ordering failure, not a retrieval one -- and 8 of those sat at rank 11-44
# where a depth-10 reranker never sees them. Widening the window and then
# trusting the CE's order more:
#   depth 10, w 0.8  (old) -> r1 51% / r5 82%
#   depth 20, w 0.8        -> r1 53% / r5 85%
#   depth 20, w 1.3        -> r1 58% / r5 86%
#   depth 20, w 2.6        -> r1 61% / r5 88%
# r5 is flat at 88% across w 1.6-3.5, so 2.6 is a plateau centre, not a peak.
# Below depth 8 the wins start dropping out; the cost is linear in depth.
RERANK_DEPTH = int(os.environ.get("MEMORY_RERANK_DEPTH", "20"))
# RRF fusion weight on the CE's ORDER against the retriever's -- not a blend
# alpha (CE logits run -11..+11 against fusion scores near 0.02, so no fixed
# alpha transfers). 0.8 was badly undertuned: it let the retriever's order
# outvote a reranker that is better than it at exactly this job.
RERANK_W = float(os.environ.get("MEMORY_RERANK_W", "2.6"))
# Rerankers whose ORDERS are fused, comma-separated. Empty means "the daemon's
# default model", i.e. the single-reranker behaviour. Every model listed must
# already be on disk; the daemon refuses to download one on the query path, so
# an unprovisioned name costs its vote and nothing else.
RERANK_MODELS = [m for m in os.environ.get("MEMORY_RERANK_MODELS", "").split(",")
                 if m.strip()] or [None]
# Per-model rerank depth, positional against RERANK_MODELS; empty means every
# model scores RERANK_DEPTH candidates. Set to a DESCENDING list to cascade: a
# cheap model orders the whole pool and an expensive one only judges the
# survivors. That is the difference between a query costing 1.3 and 10 CPU
# seconds -- jina-reranker-v2 needs 2.5-3.9s to score 20 real (687-char)
# passages against ms-marco-MiniLM-L-6's 0.25-0.42s, so what the big model is
# asked to look at IS the cost model.
RERANK_DEPTHS = [int(d) for d in os.environ.get("MEMORY_RERANK_DEPTHS", "").split(",")
                 if d.strip()]
# The retriever's OWN rank-decay constant inside the rerank fusion, separate
# from RRF_K. The two orderings do not have the same confidence profile, so
# sharing one decay constant is not a simplification, it is a claim that they
# do -- and it was false. At k=40 over a 20-candidate head the retriever's
# positions span 1/40..1/59 (a 1.48x spread) while the reranker's span
# 2.6/40..2.6/59 = .065..044: the cross-encoder's WORST position outvoted the
# retriever's BEST, so the retriever's vote was nominal and three gold cases
# sitting at retriever rank 2-3 were pushed out of the top five. A smaller k
# steepens only the retriever's curve, so a strong retrieval hit resists
# demotion while a weak one stays fully movable. Swept on the 112-case set.
RERANK_BASE_K = float(os.environ.get("MEMORY_RERANK_BASE_K", "40"))
# Confidence gate on the reranker's vote -- see rerank_fuse. FLOOR is on the raw
# cross-encoder logit; -1e9 disables the gate entirely.
RERANK_CONF_FLOOR = float(os.environ.get("MEMORY_RERANK_CONF_FLOOR", "-1e9"))
RERANK_CONF_SCALE = float(os.environ.get("MEMORY_RERANK_CONF_SCALE", "0.35"))
# Per-model RRF weights, positional against RERANK_MODELS; the last one repeats
# if the list is short. Defaults to RERANK_W for every model.
RERANK_WEIGHTS = [float(w) for w in
                  os.environ.get("MEMORY_RERANK_WEIGHTS", "").split(",")
                  if w.strip()] or [RERANK_W]
# Reranking gets its OWN deadline, larger than the vector arm's 1.5s. Sharing
# that deadline silently capped which rerankers could exist: a model needing
# 2.5-3.9s per query returned nothing, every time, and the fallback is the
# unreranked order -- so it scored EXACTLY the reranking-disabled baseline and
# read as a bad model rather than an unserved one. A deadline is a statement
# about how long the caller will wait, and the two arms do not have the same
# answer; the vector arm has a cheap fallback and reranking's fallback is to
# give up its entire contribution.
RERANK_DEADLINE = float(os.environ.get("MEMORY_RERANK_TIMEOUT", "6.0"))
# 700 characters is not a cost compromise, it is the ACCURACY optimum, and the
# intuition that more context helps is wrong here: at depth 20 / w 2.6, 1400
# and 2200 chars both score 55%/85% against 700's 61%/88%. Past ~700 the passage
# starts overflowing the 512-token window and the tail -- the agy questions,
# which are the most query-like text in the corpus -- is what gets truncated
# away. 400 is too short and gives up 2 points.
RERANK_CHARS = int(os.environ.get("MEMORY_RERANK_CHARS", "700"))
# What text the cross-encoder is shown. "enriched" is summary + topics + every
# generated question, truncated; "focused" is summary + the single question arm D
# matched against this query.
#
# "focused" IS REJECTED, and it is kept here because the result is the useful
# part. The cross-encoder is ~90% of a query's cost and that cost is tokens read,
# so showing it only the question that already matched looked like a free 57%
# cut (686 -> 295 chars/passage). Measured on the 112-case set it costs
# 62/88 -> 54/83. The reranker is not confirming the match arm D found; it is
# using the topics and the OTHER four questions as evidence about what the
# document is, which is exactly the corpus knowledge the bi-encoder lacks.
# Narrowing its input to the part that already agreed with the query removes the
# independent judgement that made it worth running. A cheaper passage is only
# cheaper if the stage still does its job.
RERANK_TEXT = os.environ.get("MEMORY_RERANK_TEXT", "enriched")


def rerank_passages(db, keys, best_q=None):
    """Build the passage the cross-encoder judges, for each (root_tag, rel_path).

    Deliberately the ENRICHED fields, not the file body: two thirds of this
    corpus is source code or 30k-word transcripts, and neither survives a
    512-token window. The agy-written summary and questions are what make the
    corpus searchable in the first place, so they are what gets reranked.

    Reads them here rather than reusing the summary already on the result row,
    because the row has no topics or questions — and passage composition is the
    experiment. The +7.7 points were measured on THIS text; scoring something
    else would be shipping an unmeasured change under a measured number.

    Returns (kept_keys, passages) in step. A key with no docs row is dropped
    rather than scored on its path alone: an unscored candidate keeps its
    existing position, which is the right answer for a file the enriched arm
    never described.

    Fetched in ONE statement, not one per key, because `docs` is an FTS5 table
    whose root_tag and rel_path are UNINDEXED: every lookup is a full scan and no
    ordinary index can be added to a virtual table. Ten separate lookups measured
    57.8ms -- two thirds of the reranker's entire budget spent finding the text,
    not scoring it. One batched scan does the same work in 7.2ms.
    """
    if not keys:
        return [], []
    ph = ",".join("?" * len(keys))
    try:
        found = {
            (r[0], r[1]): r[2:] for r in db.execute(
                "SELECT root_tag, rel_path, summary, topics, questions "
                f"FROM docs WHERE rel_path IN ({ph})", [k[1] for k in keys])
        }
    except Exception:
        return [], []
    # Filtered on rel_path alone above (a two-column IN cannot use row values on
    # every sqlite build here), so the root_tag half of the key is matched now --
    # otherwise a path that exists under two roots would take the wrong summary.
    kept, passages = [], []
    for key in keys:
        row = found.get(key)
        if row is None:
            continue
        parts = [key[1].replace("/", " ").replace("-", " ").replace("_", " ")]
        if RERANK_TEXT == "focused" and best_q and key in best_q:
            # summary + the ONE question arm D matched, instead of summary +
            # topics + all five questions. Fewer tokens for the cross-encoder to
            # read, and the question it reads is the one that actually resembles
            # the query rather than four others averaged in beside it.
            parts += [str(row[0] or ""), best_q[key]]
        else:
            parts += [str(f) for f in row if f]
        kept.append(key)
        passages.append(" ".join(parts)[:RERANK_CHARS])
    return kept, passages


def rerank_fuse(keys, ce_scores, k=None, weights=None):
    """RRF over the existing order plus one order per cross-encoder.

    `ce_scores` is either a single key -> float mapping or a LIST of them, one
    per reranker in RERANK_MODELS order. Each may cover only some of `keys`;
    anything unscored keeps its incoming position and takes no cross-encoder
    credit, so a partial result degrades smoothly instead of scrambling the list.

    Several rerankers are fused rather than one being chosen because they fail
    on DIFFERENT cases, and the retriever keeps a vote of its own throughout.
    Measured on the 112-case gold set, ms-marco-MiniLM-L-6 reaches r1 61 / r5 88
    and jina-reranker-v2 reaches r1 55 / r5 93 — but only 9 cases are missed by
    both, so neither model alone is the ceiling. The retriever's vote is what
    protects the case it already ranks 2nd from a reranker that happens to be
    confused by it; two such cases were being actively thrown out of the top
    five by a single amplified reranker.
    """
    k = RRF_K if k is None else k
    bk = RERANK_BASE_K
    maps = [ce_scores] if isinstance(ce_scores, dict) else list(ce_scores)
    maps = [m for m in maps if m]
    if not maps:
        return list(keys)
    if weights is None:
        weights = RERANK_WEIGHTS
    # Scored by ANY reranker is enough to be reordered; a key no model scored
    # keeps its retriever position in the tail.
    scored = {x for m in maps for x in m}
    head = [x for x in keys if x in scored]
    if len(head) < 2:
        return list(keys)
    base_pos = {x: i for i, x in enumerate(head)}
    contrib = {x: 1.0 / (bk + base_pos[x]) for x in head}
    for i, m in enumerate(maps):
        w = weights[i] if i < len(weights) else weights[-1] if weights else RERANK_W
        # MEASURED AND REJECTED (2026-08-02). Kept OFF by default, and kept here
        # so it is not re-derived from the same convincing correlation.
        #
        # The idea: RRF keeps only the ORDER a reranker implies and throws its
        # scores away, so "the best of ten things I consider irrelevant" and "the
        # answer" cast identical votes. ms-marco emits a raw logit, and the sign
        # looked diagnostic -- on the 112-case gold set a max score below zero
        # occurs in 71% of misses but only 31% of hits, a 25% miss rate against
        # 12% overall. Two of the three cases the reranker actively pushed out of
        # the top five were all-negative lists.
        #
        # It does not survive: r@5 88 (off) -> 86 -> 85 -> 85 -> 84 as the floor
        # rises. A low max score marks a HARD QUERY, not a confused reranker --
        # and on a hard query the retriever is uncertain too, so muting the
        # reranker's vote loses more cases than the pushouts it rescues. The
        # correlation is real and points the wrong way, which is the failure mode
        # to remember here.
        if m and max(m.values()) < RERANK_CONF_FLOOR:
            w *= RERANK_CONF_SCALE
        ranked = sorted((x for x in head if x in m), key=lambda x: -m[x])
        pos = {x: j for j, x in enumerate(ranked)}
        for x in ranked:
            contrib[x] += w / (k + pos[x])
    new = sorted(head, key=lambda x: (-contrib[x], x))
    tail = [x for x in keys if x not in scored]
    return new + tail
