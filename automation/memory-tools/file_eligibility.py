#!/usr/bin/env python3
"""Which files may be indexed, and how their text is read.

Extracted from semantic-agy-build.py so the enrichment pass and the chunk/vector
pass cannot disagree about what content IS. They must walk the identical set:
a file that one indexes and the other does not produces a document that is
findable by one arm of the search and invisible to the other, which looks like a
ranking problem and is actually a scope problem. The same reasoning already
forced the shared vocabulary in index_scope.py.

Behaviour here is a verbatim move, not a rewrite. Any change to eligibility is a
change to BOTH passes and needs a rebuild of both.
"""
import os, re, subprocess, shutil
from pathlib import Path

from index_scope import IGNORED_DIR_NAMES, is_excluded

IGNORED_DIRS = set(IGNORED_DIR_NAMES)

# There is deliberately NO secrets denylist here any more. It was removed
# 2026-07-30 on instruction: eligibility decides what is SEARCHABLE, and a file
# is not worth losing because its name or its contents mention a credential.
# Confidentiality is handled at the only boundary where it is actually at stake
# -- redact_secrets(), applied to text on its way to agy. See that function.

# Binary documents — extracted to text via an external tool, then treated as prose.
DOC_EXTS = {".pdf", ".docx", ".doc", ".rtf"}
DOC_MAX_BYTES = 12_000_000
EXTS = {
    ".md", ".markdown", ".txt", ".text", ".rst", ".csv", ".tsv", ".json", ".jsonl",
    ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".env.example",
    ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".sh", ".bash", ".zsh",
    ".rb", ".go", ".rs", ".swift", ".java", ".kt", ".c", ".h", ".cpp", ".hpp",
    ".cc", ".m", ".mm", ".sql", ".html", ".htm", ".css", ".scss", ".lua", ".pl",
    ".applescript", ".plist", ".xml", ".gradle", ".vue", ".svelte",
}
MAX_FILE_BYTES = 400_000  # skip giant files (logs, minified bundles, data dumps)

CODE_EXTS = {
    ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".sh", ".bash", ".zsh",
    ".rb", ".go", ".rs", ".swift", ".java", ".kt", ".c", ".h", ".cpp", ".hpp",
    ".cc", ".m", ".mm", ".sql", ".lua", ".pl", ".gradle", ".vue", ".svelte",
    ".css", ".scss", ".applescript",
}

STALE_RE = re.compile(r"^status:\s*stale\s*$", re.MULTILINE)


def is_code(rel):
    s = Path(rel).suffix.lower()
    return s in CODE_EXTS or s == ""       # extension-less = shebang script


def is_stale_capture(p):
    """True for a markdown file whose frontmatter carries `status: stale`
    (set by memory-prune on superseded captures)."""
    if p.suffix.lower() not in (".md", ".markdown"):
        return False
    try:
        with open(p, encoding="utf-8", errors="ignore") as f:
            head = f.read(400)
    except OSError:
        return False
    return head.startswith("---") and bool(STALE_RE.search(head))


def is_shebang_script(p):
    """True for an extension-less text file starting with a shebang — e.g. the
    helper scripts in ~/.local/bin, which carry no suffix."""
    try:
        with open(p, "rb") as f:
            return f.read(2) == b"#!"
    except OSError:
        return False


# High-confidence credential shapes, redacted from ANY text about to leave the
# machine. These rewrite bytes in place, so they carry only patterns that cannot
# plausibly match ordinary source -- a false positive here corrupts a record,
# unlike the old eligibility denylist where it merely dropped a file.
_REDACT_RES = [
    re.compile(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{16,}"),
    re.compile(r"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{30,}"),
    re.compile(r"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"(?<![A-Za-z0-9])xox[baprs]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}"),
    re.compile(r"(?<![A-Za-z0-9])(eyJ[A-Za-z0-9_\-]{10,}\.){2}[A-Za-z0-9_\-]{10,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
               re.DOTALL),
]
# Assignment form: keep the NAME (it is real search signal — a reader looking for
# "where is the Discord token configured" should still find the file) and destroy
# only the value.
# \w* on BOTH sides, because the credential word is usually a suffix or infix of
# the real name: DISCORD_TOKEN, MY_API_KEY, gh_access_token. Anchoring on \b alone
# matched none of those — an underscore is a word character, so there is no
# boundary in front of TOKEN.
_REDACT_ASSIGN = re.compile(
    r"""(?i)(\w*(?:api[_-]?key|apikey|token|secret|password|passwd|
        credential|bearer|private[_-]?key)\w*['"]?\s*[:=]\s*)
        (['"]?)([^\s'"#;]{8,})(\2)""", re.VERBOSE)


def redact_secrets(text):
    """Strip credential-shaped substrings from text before it is sent anywhere.

    Applied to every file at the upload boundary, not at the eligibility gate.
    That placement is deliberate: eligibility can only DROP a file, and dropping
    on a broad pattern would silently delete legitimate source from the index
    (`password = get_password()` matches the assignment form). Redaction keeps
    the file searchable and removes only the bytes that must not leave.
    """
    if not text:
        return text
    for rx in _REDACT_RES:
        text = rx.sub("[REDACTED]", text)
    return _REDACT_ASSIGN.sub(lambda m: f"{m.group(1)}{m.group(2)}[REDACTED]{m.group(4)}", text)


def iter_files(root, root_excludes, skips=None):
    """Yield every indexable file under root. `skips` (a dict) collects the
    reason each rejected file was rejected — never drop a file silently, because
    a dropped file is indistinguishable from a file that was never there."""
    skips = {} if skips is None else skips

    def _skip(reason, p):
        skips.setdefault(reason, []).append(str(p))

    for dirpath, dirnames, filenames in os.walk(root):
        # prune ignored/sensitive/noise dirs AND any virtualenv (pyvenv.cfg probe)
        dirnames[:] = [d for d in dirnames
                       if d not in IGNORED_DIRS and not d.startswith(".venv")
                       and not os.path.exists(os.path.join(dirpath, d, "pyvenv.cfg"))
                       and not is_excluded(Path(dirpath) / d, root, root_excludes)]
        for name in filenames:
            p = Path(dirpath) / name
            # Codex task-index/app-state files carry runtime UI state, not durable
            # semantic-search source material.
            if (root == Path.home() / ".codex" and Path(dirpath) == root
                    and name in {".codex-global-state.json", "session_index.jsonl"}):
                continue
            ext = p.suffix.lower()
            is_doc = ext in DOC_EXTS
            if ext not in EXTS and not is_doc:
                if not (ext == "" and is_shebang_script(p)):
                    continue
            # No secret-based exclusion. Index everything eligible, by explicit
            # instruction (2026-07-30). The name+content denylist was dropping 23
            # real source files -- the CodexBar OAuth and credential-store test
            # suites, which are precisely the files worth being able to find --
            # because a filename mentioning credentials is a claim about TOPIC,
            # not evidence of a live key. Confidentiality is enforced where it
            # actually matters instead: redact_secrets() scrubs credential-shaped
            # bytes at the agy upload boundary, so nothing sensitive leaves the
            # machine while the local index stays complete.
            if is_stale_capture(p):
                _skip("stale_capture", p)
                continue
            try:
                if not p.is_file():
                    continue
                if p.stat().st_size > (DOC_MAX_BYTES if is_doc else MAX_FILE_BYTES):
                    _skip("too_large", p)
                    continue
            except OSError:
                _skip("unreadable", p)
                continue
            yield p


def extract_document(p):
    """Plain text from a binary doc. docx/doc/rtf via macOS textutil (built-in);
    pdf via pdftotext (poppler) if installed. Returns '' on failure."""
    ext = p.suffix.lower()
    try:
        if ext in (".docx", ".doc", ".rtf"):
            r = subprocess.run(["textutil", "-convert", "txt", "-stdout", str(p)],
                               capture_output=True, text=True, timeout=60)
            return r.stdout or ""
        if ext == ".pdf" and shutil.which("pdftotext"):
            r = subprocess.run(["pdftotext", "-q", "-nopgbrk", str(p), "-"],
                               capture_output=True, text=True, timeout=120)
            return r.stdout or ""
    except Exception:
        return ""
    return ""


def read_text(p):
    if p.suffix.lower() in DOC_EXTS:
        return extract_document(p)
    try:
        return p.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        try:
            return p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            return ""


_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")


def path_tokens(root_tag, rel):
    """Searchable text for a file's location: every path segment, split on the
    usual separators and camelCase, with the extension kept as its own token."""
    text = f"{root_tag}/{rel}"
    text = _CAMEL.sub(" ", text)
    words = re.split(r"[^A-Za-z0-9]+", text)
    seen, out = set(), []
    for w in words:
        w = w.strip()
        if not w or len(w) > 40:
            continue
        k = w.lower()
        if k in seen:
            continue
        seen.add(k)
        out.append(w)
    return " ".join(out)
