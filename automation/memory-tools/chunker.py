#!/usr/bin/env python3
"""Split a file into retrievable chunks.

Why this exists: the index stored ONE row per file, capped at 20,000 characters.
Measured consequences — 175 of 2489 documents were truncated (including the
highest-value curated files: wiki/preferences.md, wiki/workflows.md, current.md),
and a 20k document carrying a 119-character summary dilutes both BM25 and any
embedding until a precise question cannot distinguish it from a vague one.

Two hard requirements, both learned from bugs already in this codebase:

1. DETERMINISTIC. Same bytes in, same chunks out, forever. Chunk identity is part
   of the index fingerprint; if chunking drifted, old and new chunks would coexist
   silently and rank against each other. No clocks, no randomness, no dict order.
2. NEVER SILENTLY DROP. The recurring defect here is a cheap proxy that discards
   good data quietly (a filename denylist eating a real capture, a display cap
   reported as a health state, this very 20k truncation). Every bound in this
   module is generous, counted, and reported to the caller, which surfaces it as a
   FAILING health check rather than a log line nobody reads.
"""
import re
from pathlib import Path

# ~4 chars per token for English prose; these are character budgets, not token
# counts, because the tokenizer is a model detail and chunking must not depend on
# which embedding model is loaded. Kept comfortably under bge's 512-token window.
TARGET_CHARS = 1800
OVERLAP_CHARS = 220
MIN_CHARS = 80          # below this a chunk is merged forward, not emitted alone
MAX_CHARS = 2600        # hard ceiling for one chunk before a mid-text split

# A file yielding more than this is reported to the caller as an anomaly. At the
# 400,000-byte file ceiling enforced upstream, a normal file produces ~220 chunks,
# so this is a "something is pathological" signal, not a routine cap.
MAX_CHUNKS_PER_FILE = 400

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
MD_EXTS = {".md", ".markdown", ".rst", ".txt", ".text"}


def _split_oversized(text, limit=MAX_CHARS):
    """Break text that has no usable structure. Prefers a paragraph break, then a
    line break, then a hard character cut.

    The hard cut is not optional: a minified bundle or a JSON dump can be one line
    of 300,000 characters, and a splitter that only cuts on newlines would emit it
    as a single chunk that overflows the model's window and gets truncated by the
    tokenizer — silent data loss of exactly the kind this module exists to prevent.
    """
    out = []
    while len(text) > limit:
        window = text[:limit]
        cut = window.rfind("\n\n")
        if cut < limit // 3:
            cut = window.rfind("\n")
        if cut < limit // 3:
            cut = window.rfind(" ")
        if cut < limit // 3:
            cut = limit                      # no boundary at all: cut mid-token
        out.append(text[:cut])
        text = text[cut:].lstrip("\n")
    if text:
        out.append(text)
    return out


def _markdown_sections(text):
    """[(heading_breadcrumb, section_text)] honouring fenced code blocks.

    Headings inside a ``` fence are content, not structure — a note about
    markdown, or any shell script embedded in a note, would otherwise be shredded
    at every commented line beginning with #.
    """
    lines = text.splitlines()
    sections, stack, buf, fence = [], [], [], None
    crumb = ""

    def flush():
        if buf:
            body = "\n".join(buf).strip()
            if body:
                sections.append((crumb, body))
        buf.clear()

    for line in lines:
        m = FENCE_RE.match(line)
        if m:
            marker = m.group(1)
            if fence is None:
                fence = marker
            elif line.strip().startswith(fence):
                fence = None
            buf.append(line)
            continue
        if fence is None:
            h = HEADING_RE.match(line)
            if h:
                flush()
                depth = len(h.group(1))
                stack[:] = stack[:depth - 1]
                stack.append(h.group(2).strip())
                crumb = " > ".join(s for s in stack if s)
                buf.append(line)
                continue
        buf.append(line)
    flush()
    return sections or [("", text.strip())]


def _plain_sections(text):
    """Blank-line-separated blocks, for files with no heading structure."""
    blocks = [b.strip() for b in re.split(r"\n\s*\n", text) if b.strip()]
    return [("", b) for b in blocks] or [("", text.strip())]


def chunk_text(text, rel_path=""):
    """Return [{ordinal, heading, text}] — deterministic for identical input.

    Chunks carry their heading breadcrumb as a prefix so an embedding of
    "must be relative, never memory-root-relative" still knows it is under
    "Chat file links". Without it, mid-document chunks lose all context about
    what they are describing, which is the classic failure of naive chunking.
    """
    text = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    if not text.strip():
        return []

    ext = Path(rel_path).suffix.lower()
    sections = _markdown_sections(text) if ext in MD_EXTS or "#" in text[:2000] \
        else _plain_sections(text)

    chunks, cur, cur_crumb = [], "", ""
    for crumb, body in sections:
        for piece in (_split_oversized(body) if len(body) > MAX_CHARS else [body]):
            if not cur:
                cur, cur_crumb = piece, crumb
            elif len(cur) + len(piece) + 2 <= TARGET_CHARS and crumb == cur_crumb:
                cur = cur + "\n\n" + piece
            else:
                chunks.append((cur_crumb, cur))
                # Overlap carries the tail of the previous chunk forward so a fact
                # split across a boundary is still wholly present in one chunk.
                tail = cur[-OVERLAP_CHARS:] if len(cur) > OVERLAP_CHARS * 2 else ""
                cur = (tail + "\n\n" + piece).strip() if tail else piece
                cur_crumb = crumb
    if cur:
        chunks.append((cur_crumb, cur))

    # Merge runt chunks forward rather than emitting a 12-character chunk that
    # will match everything weakly and nothing well.
    merged = []
    for crumb, body in chunks:
        if merged and len(body) < MIN_CHARS and merged[-1][0] == crumb:
            merged[-1] = (crumb, merged[-1][1] + "\n\n" + body)
        else:
            merged.append((crumb, body))

    return [{"ordinal": i, "heading": crumb,
             "text": (crumb + "\n\n" + body) if crumb else body}
            for i, (crumb, body) in enumerate(merged)]


def chunk_file(text, rel_path=""):
    """chunk_text plus the overflow verdict. Returns (chunks, overflow_count).

    overflow_count > 0 means chunks were dropped and the caller MUST surface it as
    a failure, not a note.
    """
    chunks = chunk_text(text, rel_path)
    overflow = max(0, len(chunks) - MAX_CHUNKS_PER_FILE)
    return chunks[:MAX_CHUNKS_PER_FILE], overflow
