#!/usr/bin/env python3
"""Local ONNX text embeddings, with an explicit compatibility contract.

THE constraint that shapes this whole file: query and document vectors must come
from the same model, the same pooling, the same normalization, and the same
instruction prefix. Violate any one and cosine similarity silently stops meaning
anything — the search does not error, it just quietly gets worse. That is the
single most dangerous failure mode in a system meant to run untouched for years,
so every one of those choices is frozen into FINGERPRINT and stored alongside the
vectors. A mismatch forces a rebuild instead of serving mixed-model garbage.

Uses onnxruntime + tokenizers directly rather than fastembed. Measured on this
machine, per process: fastembed 430ms, this 160ms. The difference is almost
entirely `import fastembed` pulling in huggingface_hub and its dependency tree —
the actual embedding is 4.5ms. fastembed is still used to DOWNLOAD the model
(one time, offline afterwards), just not on the query path.

Every entry point fails soft: callers get None or an exception they are expected
to catch, and search degrades to BM25 rather than dying. A memory system that
returns worse results is annoying; one that returns a traceback is broken.
"""
import os, hashlib
from pathlib import Path

MODELS_DIR = Path(os.environ.get(
    "MEMORY_MODELS_DIR", str(Path.home() / ".local/share/memory-models"))).expanduser()

# ---- the contract ----------------------------------------------------------
# bge-small-en-v1.5: 384 dims, CLS pooling, L2-normalized, and ASYMMETRIC — the
# query side takes an instruction prefix the passage side must NOT have. Getting
# that backwards (or omitting it) is a well-known footgun that costs several
# points of recall while looking completely healthy, which is why it lives here
# as data and is asserted by the self-test rather than being a caller's problem.
#
# The model half is a named PRESET rather than free-form env vars, so a bake-off
# cannot invent an inconsistent combination (bge-base's repo with bge-small's
# dim silently produces garbage). Switching presets changes model_id/onnx_repo/dim,
# all three of which are in fingerprint() -- so a preset change forces a rebuild
# and an index built under the other preset reads as a mismatch rather than being
# served as if it agreed. Every BGE v1.5 variant shares the pooling, the
# normalisation and the query instruction prefix; only size differs.
_PRESETS = {
    "bge-small": ("BAAI/bge-small-en-v1.5", "qdrant/bge-small-en-v1.5-onnx-q", 384),
    "bge-base":  ("BAAI/bge-base-en-v1.5",  "qdrant/bge-base-en-v1.5-onnx-q",  768),
}
_PRESET = os.environ.get("MEMORY_EMBED_PRESET", "bge-small")
if _PRESET not in _PRESETS:
    raise SystemExit(f"MEMORY_EMBED_PRESET={_PRESET!r} is not one of {sorted(_PRESETS)}")
_MODEL_ID, _ONNX_REPO, _DIM = _PRESETS[_PRESET]

CONTRACT = {
    "model_id": _MODEL_ID,
    "onnx_repo": _ONNX_REPO,
    "dim": _DIM,
    "pooling": "cls",
    "normalize": True,
    "query_prefix": "Represent this sentence for searching relevant passages: ",
    "passage_prefix": "",
    "max_tokens": 512,
    # Only prose is embedded. Measured: with code, logs and config in the vector
    # table the arm scored WORSE than having no vector arm at all (see fusion.py).
    # This is a BUILD-time scope, not a query-time filter, so the table cannot
    # disagree with the searcher — and it is in the fingerprint, so flipping it
    # forces a rebuild instead of silently serving a half-populated index.
    "vector_scope": "prose",
    "revision": 2,
}


def fingerprint():
    """Stable identity of everything that must match between index and query."""
    from chunker import TARGET_CHARS, OVERLAP_CHARS, MAX_CHARS, MIN_CHARS
    parts = [
        "v%d" % CONTRACT["revision"], CONTRACT["model_id"], CONTRACT["onnx_repo"],
        str(CONTRACT["dim"]), CONTRACT["pooling"], str(CONTRACT["normalize"]),
        CONTRACT["query_prefix"], CONTRACT["passage_prefix"],
        str(CONTRACT["max_tokens"]), CONTRACT["vector_scope"],
        "chunk:%d/%d/%d/%d" % (TARGET_CHARS, OVERLAP_CHARS, MAX_CHARS, MIN_CHARS),
    ]
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16]


class EmbedderUnavailable(RuntimeError):
    """Raised when embeddings cannot be produced. ALWAYS catchable: the caller's
    job is to fall back to keyword search, never to propagate this to the user."""


def _snapshot_dir(repo=None, nested=False):
    """Path to a downloaded ONNX snapshot, or None if it is not present.

    `nested` searches subdirectories for the .onnx. Repo layouts differ: the
    qdrant embedding repo puts model.onnx at the snapshot root, the Xenova
    reranker puts it under onnx/. A non-recursive glob reports the second as
    "not downloaded" while it sits right there.
    """
    repo = "models--" + (repo or CONTRACT["onnx_repo"]).replace("/", "--")
    base = MODELS_DIR / repo / "snapshots"
    if not base.is_dir():
        return None
    snaps = sorted(p for p in base.iterdir() if p.is_dir())
    for s in snaps:
        found = s.rglob("*.onnx") if nested else s.glob("*.onnx")
        if (s / "tokenizer.json").exists() and any(found):
            return s
    return None


def _runtime_graph(snap, ort):
    """Path to a graph-optimized copy of the model, building it once if needed.

    ORT can either optimize the graph at every session creation or load one that
    was optimized ahead of time. Measured here: optimizing on load costs 86ms of
    startup and gives 9ms inference; skipping optimization costs 32ms of startup
    but 21ms inference. Neither is good — doing it once offline gets BOTH, and
    inference is the cost paid on every single query.

    Returns None on any failure. This is an accelerator, never a requirement.
    """
    onnx = sorted(snap.glob("*.onnx"))
    if not onnx:
        return None
    base = next((p for p in onnx if "optimized" in p.name), onnx[0])
    if base.name == "model_runtime.onnx":
        return base
    out = snap / "model_runtime.onnx"
    stamp = snap / "model_runtime.ort-version"
    # The optimized graph is tied to the ORT build that produced it. Regenerate on
    # an upgrade rather than trusting a file written by a different optimizer.
    # ORT warns that this graph carries hardware-specific optimizations, so the
    # stamp keys on the CPU architecture as well as the ORT build.
    import platform
    want = f"{ort.__version__} {platform.machine()}"
    if out.exists() and stamp.exists() and stamp.read_text().strip() == want:
        return out
    try:
        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        so.optimized_model_filepath = str(out)
        ort.InferenceSession(str(base), so, providers=["CPUExecutionProvider"])
        stamp.write_text(want)
        return out if out.exists() else None
    except Exception:
        return None


# The reranker model. Kept beside the embedder because it shares the download
# cache and the same hard rule: provisioned ahead of time, never on the query
# path. It is NOT part of CONTRACT and deliberately not in the fingerprint — the
# reranker only reorders results, so changing it cannot make a stored vector
# table wrong, and forcing a full re-embed to try a different one would be a
# self-inflicted cost.
RERANK_REPO = os.environ.get("MEMORY_RERANK_MODEL",
                             "Xenova/ms-marco-MiniLM-L-6-v2")


def rerank_snapshot_dir(repo=None):
    """Snapshot for a reranker, or None if it has not been downloaded."""
    return _snapshot_dir(repo or RERANK_REPO, nested=True)


def ensure_rerank_model(quiet=False, repo=None):
    """Download the reranker if absent. Network only — never on the query path.

    Returns the snapshot dir, or None if it could not be provisioned. Returning
    None rather than raising is the point: search works fine without a reranker,
    so a failure here must not fail a build that is otherwise complete.
    """
    repo = repo or RERANK_REPO
    if rerank_snapshot_dir(repo):
        return rerank_snapshot_dir(repo)
    os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS_DIR))
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        from fastembed.rerank.cross_encoder import TextCrossEncoder
        TextCrossEncoder(model_name=repo)
    except Exception as e:
        if not quiet:
            print(f"reranker model unavailable: {e}")
        return None
    return rerank_snapshot_dir(repo)


def ensure_model(quiet=False):
    """Download the model if absent. Network only — never called on the query path.

    Kept separate from load() on purpose: a query must never trigger a download.
    A first-run download inside a search would turn a 78ms command into a 40s one
    on someone's laptop with no explanation, and would fail outright offline.
    """
    if _snapshot_dir():
        return _snapshot_dir()
    os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS_DIR))
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        from fastembed import TextEmbedding
        TextEmbedding(CONTRACT["model_id"])          # downloads into MODELS_DIR
    except Exception as e:
        raise EmbedderUnavailable(f"model download failed: {e}") from e
    d = _snapshot_dir()
    if not d:
        raise EmbedderUnavailable("model downloaded but no usable snapshot found")
    try:                                   # pre-build the fast graph while online
        import onnxruntime as ort
        _runtime_graph(d, ort)
    except Exception:
        pass
    if not quiet:
        print(f"embedder: model ready at {d}")
    return d


class Embedder:
    """Lazy-loading ONNX embedder. Construction is free; cost is on first embed."""

    def __init__(self):
        self._sess = None
        self._tok = None
        self._np = None

    def _load(self):
        if self._sess is not None:
            return
        snap = _snapshot_dir()
        if snap is None:
            raise EmbedderUnavailable(
                "embedding model is not downloaded (run: memory-vector-build --setup)")
        try:
            import numpy as np
            import onnxruntime as ort
            from tokenizers import Tokenizer
        except ImportError as e:
            raise EmbedderUnavailable(f"python runtime is missing a dependency: {e}") from e
        try:
            tok = Tokenizer.from_file(str(snap / "tokenizer.json"))
            tok.enable_truncation(max_length=CONTRACT["max_tokens"])
            tok.enable_padding(length=None)
            onnx = sorted(snap.glob("*.onnx"))
            model = _runtime_graph(snap, ort) or next(
                (p for p in onnx if "optimized" in p.name), onnx[0])
            so = ort.SessionOptions()
            # One thread: these are single short texts on the query path, and
            # thread-pool spin-up costs more than it saves at this size. The build
            # path batches instead, which is where the parallelism actually pays.
            so.intra_op_num_threads = int(os.environ.get("MEMORY_EMBED_THREADS", "1"))
            # ORT's CPU arena keeps allocations around between runs. It is the
            # dominant term in this process's RSS during a bulk build (~2.4GB) and
            # it scales with batch size and sequence length, not corpus size.
            # Left on by default because it is what makes repeated inference fast;
            # MEMORY_EMBED_ARENA=0 trades throughput for a much smaller footprint.
            so.enable_cpu_mem_arena = os.environ.get("MEMORY_EMBED_ARENA", "1") != "0"
            so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
            sess = ort.InferenceSession(str(model), so, providers=["CPUExecutionProvider"])
        except Exception as e:
            raise EmbedderUnavailable(f"model load failed: {e}") from e
        self._np, self._tok, self._sess = np, tok, sess
        self._inputs = {i.name for i in sess.get_inputs()}

    def _embed(self, texts):
        self._load()
        np = self._np
        enc = self._tok.encode_batch(list(texts))
        feed = {
            "input_ids": np.array([e.ids for e in enc], dtype=np.int64),
            "attention_mask": np.array([e.attention_mask for e in enc], dtype=np.int64),
        }
        if "token_type_ids" in self._inputs:
            feed["token_type_ids"] = np.zeros_like(feed["input_ids"])
        out = self._sess.run(None, feed)[0]
        vecs = out[:, 0] if CONTRACT["pooling"] == "cls" else out.mean(axis=1)
        if CONTRACT["normalize"]:
            n = np.linalg.norm(vecs, axis=1, keepdims=True)
            vecs = vecs / np.maximum(n, 1e-12)
        return vecs.astype("float32")

    def embed_passages(self, texts):
        p = CONTRACT["passage_prefix"]
        return self._embed([p + t for t in texts] if p else list(texts))

    def embed_query(self, text):
        return self._embed([CONTRACT["query_prefix"] + text])[0]


def self_test():
    """Assert the properties the contract claims. Run by --version health probes.

    This exists because every one of these can break WITHOUT an error: a wrong
    dimension only shows up as a sqlite-vec insert failure much later, an
    un-normalized vector makes cosine scores incomparable, and a missing query
    prefix just quietly loses recall.
    """
    import numpy as np
    e = Embedder()
    v = e.embed_passages(["the quick brown fox", "a totally unrelated sentence"])
    assert v.shape == (2, CONTRACT["dim"]), f"dim {v.shape} != {CONTRACT['dim']}"
    norms = np.linalg.norm(v, axis=1)
    assert np.allclose(norms, 1.0, atol=1e-3), f"not unit-normalized: {norms}"
    q = e.embed_query("what does a fox look like")
    assert q.shape == (CONTRACT["dim"],)
    # The query prefix must actually change the vector, or it is not being applied.
    bare = e._embed(["what does a fox look like"])[0]
    assert float(np.dot(q, bare)) < 0.9999, "query prefix is not being applied"
    # Sanity: related text must beat unrelated text, or pooling/normalization is wrong.
    assert float(np.dot(q, v[0])) > float(np.dot(q, v[1])), "ranking sanity failed"
    return {"dim": int(v.shape[1]), "fingerprint": fingerprint(),
            "model": CONTRACT["model_id"]}


if __name__ == "__main__":
    import sys, json
    if "--setup" in sys.argv:
        ensure_model()
    try:
        print(json.dumps(self_test(), indent=2))
    except Exception as exc:
        print(f"embedder self-test FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
