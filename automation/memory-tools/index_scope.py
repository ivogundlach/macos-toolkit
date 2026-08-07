#!/usr/bin/env python3
"""Shared path-scope rules for semantic indexing."""

import os
from pathlib import Path


# Derived dependency/build trees are never authored memory content.
ALWAYS_EXCLUDED_DIRS = {".build"}


def load_root_excludes(root):
    """Return relative directory prefixes excluded for this exact root.

    Config format: absolute-root<TAB>relative-directory. This lets a dedicated
    child root remain indexed while preventing duplicate indexing through a
    broader parent root.
    """
    root = Path(root).expanduser().resolve()
    config = Path(os.environ.get(
        "MEMORY_SEMANTIC_SCOPE_FILE",
        str(Path.home() / ".memory/index-scope-excludes.tsv"),
    )).expanduser()
    prefixes = []
    try:
        lines = config.read_text(encoding="utf-8").splitlines()
    except OSError:
        return prefixes
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#") or "\t" not in line:
            continue
        configured_root, relative = line.split("\t", 1)
        try:
            if Path(configured_root).expanduser().resolve() != root:
                continue
        except OSError:
            continue
        relative = relative.strip().strip("/")
        if relative and relative not in (".", ".."):
            prefixes.append(Path(relative))
    return prefixes


def relative_path(path, root):
    path = Path(path)
    root = Path(root).expanduser().resolve()
    if not path.is_absolute():
        path = root / path
    try:
        return path.resolve().relative_to(root)
    except (OSError, ValueError):
        return None


def is_excluded(path, root, prefixes=None):
    """True when path is in a derived tree or configured excluded subtree."""
    rel = relative_path(path, root)
    if rel is None:
        return True
    if any(part in ALWAYS_EXCLUDED_DIRS for part in rel.parts):
        return True
    for prefix in prefixes if prefixes is not None else load_root_excludes(root):
        if rel == prefix or prefix in rel.parents:
            return True
    return False


# ---- shared scope vocabulary -------------------------------------------------
# Directory names and prose extensions that every scope-aware tool agrees on.
# Kept here rather than in one tool so the indexer and the coverage-drift
# detector cannot disagree about what counts as content — a detector using a
# narrower idea of "noise" than the indexer would report drift that is not real.
NOISE_DIR_NAMES = {
    ".tmp", "tmp", "temp", ".temp", "venv", "virtualenv", "site-packages",
    "archived_sessions", "vendor_imports", "raycast", ".idea", "Pods",
    "DerivedData", "coverage", "htmlcov", ".terraform", ".serverless",
}
SENSITIVE_DIR_NAMES = {
    ".ssh", ".aws", ".gnupg", "gnupg", "gcloud", ".gcloud", "gh", ".op", "op",
    "1password", ".password-store", "keyrings", ".kube", ".docker",
    "Keychains", "credentials",
}
VCS_BUILD_DIR_NAMES = {
    ".git", ".hg", ".svn", "node_modules", "__pycache__", ".DS_Store",
    ".mypy_cache", ".pytest_cache", "dist", "build", ".next",
}
IGNORED_DIR_NAMES = (VCS_BUILD_DIR_NAMES | NOISE_DIR_NAMES | SENSITIVE_DIR_NAMES
                     | ALWAYS_EXCLUDED_DIRS)

# Authored text, as opposed to code or data. Coverage is measured in these
# because a folder of source files is a project, not a memory corpus.
PROSE_EXTS = {".md", ".markdown", ".txt", ".text", ".rst", ".org"}
