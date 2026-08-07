#!/usr/bin/env python3
"""Produce a deterministic, read-only inventory of the Codex skill corpus.

Usage:
  codex_skill_audit.py skills --root ~/.codex/skills --json

The output is evidence for human or agent review. It does not edit skills,
read session transcripts, or decide whether a flagged structure should change.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ALLOWED_FRONTMATTER_KEYS = {
    "allowed-tools",
    "description",
    "license",
    "metadata",
    "name",
}
EXTRANEOUS_NAMES = {
    ".DS_Store",
    "CHANGELOG.md",
    "INSTALLATION_GUIDE.md",
    "QUICK_REFERENCE.md",
    "README.md",
}
FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---(?:\n|$)", re.DOTALL)
TOP_LEVEL_KEY_RE = re.compile(r"^([A-Za-z0-9_-]+):(?:\s*(.*))?$")
SKILL_REF_RE = re.compile(r"\$([a-z][a-z0-9]*(?:-[a-z0-9]+)+)")
PLACEHOLDER_SKILL_REFS = {"name", "skill", "skill-name", "skill-name-here", "skill-x"}
PATH_RE = re.compile(
    r"(?<![`\w])(?:~/|~[A-Za-z0-9._-]+/|/Users/YOUR_USERNAME|"
    r"/Applications|/opt/homebrew|/tmp|/private/tmp)[^\s`'\"),]+"
)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_frontmatter(text: str) -> tuple[dict[str, Any], str, bool]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        return {}, text, False

    raw = match.group(1)
    body = text[match.end() :]
    data: dict[str, Any] = {}
    lines = raw.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        key_match = TOP_LEVEL_KEY_RE.match(line) if not line.startswith((" ", "\t")) else None
        if not key_match:
            index += 1
            continue
        key = key_match.group(1)
        value = (key_match.group(2) or "").strip()
        if value in {">", ">-", "|", "|-"}:
            block: list[str] = []
            index += 1
            while index < len(lines) and (lines[index].startswith((" ", "\t")) or not lines[index].strip()):
                if lines[index].strip():
                    block.append(lines[index].strip())
                index += 1
            data[key] = " ".join(block)
            continue
        data[key] = value.strip('"').strip("'")
        index += 1
    return data, body, True


def classify_description(description: str) -> dict[str, Any]:
    low = description.lower()
    phrases = (
        "use when",
        "use whenever",
        "use on",
        "trigger on",
        "when ivo",
        "ivo asks",
        "explicitly says",
        "asks to",
    )
    hits = [phrase for phrase in phrases if phrase in low]
    return {
        "label": "TRIGGER" if hits else "SUMMARY",
        "evidence": hits,
    }


def direct_children(path: Path) -> list[str]:
    if not path.is_dir():
        return []
    return sorted(child.name for child in path.iterdir())


def extraneous_files(folder: Path) -> list[str]:
    return sorted(
        str(path.relative_to(folder))
        for path in folder.rglob("*")
        if path.is_file() and path.name in EXTRANEOUS_NAMES
    )


def non_executable_scripts(folder: Path) -> list[str]:
    scripts = folder / "scripts"
    if not scripts.is_dir():
        return []
    findings = []
    for path in scripts.rglob("*"):
        if not path.is_file():
            continue
        try:
            has_shebang = path.read_bytes()[:2] == b"#!"
        except OSError:
            continue
        if has_shebang and not os.access(path, os.X_OK):
            findings.append(str(path.relative_to(folder)))
    return sorted(findings)


def canonical_validation(path: Path, validator: Path | None) -> dict[str, Any]:
    if validator is None or not validator.is_file():
        return {"available": False, "valid": None, "message": "validator unavailable"}
    try:
        result = subprocess.run(
            [sys.executable, str(validator), str(path.parent)],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"available": True, "valid": False, "message": str(error)}
    message = (result.stdout.strip() or result.stderr.strip() or "no diagnostic output")
    return {"available": True, "valid": result.returncode == 0, "message": message}


def skill_summary(
    path: Path, root: Path, known_names: set[str], validator: Path | None
) -> dict[str, Any]:
    text = read_text(path)
    frontmatter, body, valid_frontmatter = parse_frontmatter(text)
    folder = path.parent
    name = str(frontmatter.get("name") or folder.name)
    description = str(frontmatter.get("description") or "")
    keys = sorted(frontmatter)
    forbidden = sorted(set(keys) - ALLOWED_FRONTMATTER_KEYS)
    all_refs = sorted(set(SKILL_REF_RE.findall(body)) - PLACEHOLDER_SKILL_REFS)
    stale_refs = sorted(ref for ref in all_refs if ref not in known_names and ref != name)
    description_class = classify_description(description)
    agents_file = folder / "agents" / "openai.yaml"
    prompt_missing_invocation = agents_file.is_file() and f"${name}" not in read_text(agents_file)
    extra = extraneous_files(folder)
    nonexec = non_executable_scripts(folder)
    body_lines = len(body.splitlines())
    validation = canonical_validation(path, validator)

    flags: list[str] = []
    if not valid_frontmatter:
        flags.append("invalid_frontmatter")
    if "name" not in frontmatter:
        flags.append("missing_name")
    if "description" not in frontmatter:
        flags.append("missing_description")
    if forbidden:
        flags.append("forbidden_frontmatter")
    if validation["available"] and validation["valid"] is False and not forbidden:
        flags.append("canonical_validation_error")
    if description and description_class["label"] == "SUMMARY":
        flags.append("description_summary")
    if body_lines > 500:
        flags.append("body_over_500_lines")
    if folder.name != name:
        flags.append("folder_name_mismatch")
    if stale_refs:
        flags.append("stale_skill_reference")
    if prompt_missing_invocation:
        flags.append("openai_prompt_missing_skill_invocation")
    if nonexec:
        flags.append("script_not_executable")
    if extra:
        flags.append("extraneous_artifact")

    return {
        "name": name,
        "path": str(path),
        "rel": str(folder.relative_to(root)),
        "category": str(folder.relative_to(root)).split(os.sep)[0],
        "description": description,
        "description_class": description_class,
        "frontmatter_keys": keys,
        "forbidden_frontmatter_keys": forbidden,
        "canonical_validation": validation,
        "body_lines": body_lines,
        "skill_refs": sorted(ref for ref in all_refs if ref in known_names),
        "stale_skill_refs": stale_refs,
        "hardcoded_paths": sorted(set(PATH_RE.findall(body)))[:30],
        "resources": {
            "agents": direct_children(folder / "agents"),
            "assets": direct_children(folder / "assets"),
            "config": direct_children(folder / "config"),
            "references": direct_children(folder / "references"),
            "scripts": direct_children(folder / "scripts"),
        },
        "openai_prompt_missing_skill_invocation": prompt_missing_invocation,
        "non_executable_scripts": nonexec,
        "extraneous_files": extra,
        "flags": flags,
    }


def skills_command(args: argparse.Namespace) -> None:
    root = Path(args.root).expanduser().resolve()
    if not root.is_dir():
        raise SystemExit(f"skill root does not exist or is not a directory: {root}")
    paths = sorted(root.rglob("SKILL.md"))
    if not paths:
        raise SystemExit(f"skill root contains no SKILL.md files: {root}")
    known_names: set[str] = set()
    for path in paths:
        frontmatter, _, _ = parse_frontmatter(read_text(path))
        known_names.add(str(frontmatter.get("name") or path.parent.name))
    configured_validator = os.environ.get("CODEX_SKILL_VALIDATOR")
    validator = (
        Path(configured_validator).expanduser()
        if configured_validator
        else root / ".system/skill-creator/scripts/quick_validate.py"
    )
    rows = [skill_summary(path, root, known_names, validator) for path in paths]
    result = {"root": str(root), "count": len(rows), "skills": rows}
    print(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    skills = subparsers.add_parser("skills")
    skills.add_argument("--root", default="~/.codex/skills")
    skills.add_argument("--json", action="store_true", help="Compatibility flag; output is always JSON")
    skills.add_argument("--pretty", action="store_true")
    skills.set_defaults(function=skills_command)
    args = parser.parse_args()
    args.function(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
