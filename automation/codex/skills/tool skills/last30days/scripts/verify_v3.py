#!/usr/bin/env python3
"""Self-contained verification for the installed Last30Days skill."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL_ROOT / "scripts"
ENGINE = SCRIPTS / "last30days.py"


def run(command: list[str], *, timeout: int = 120, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=SKILL_ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def python_files() -> list[Path]:
    return sorted(
        path
        for path in SCRIPTS.rglob("*.py")
        if "lib/vendor" not in path.as_posix()
    )


def verify_compile(temp_root: Path) -> dict[str, object]:
    files = python_files()
    env = dict(os.environ)
    env["PYTHONPYCACHEPREFIX"] = str(temp_root / "pycache")
    result = run([sys.executable, "-m", "py_compile", *(str(path) for path in files)], env=env)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Python compilation failed")
    return {"files": len(files), "status": "ok"}


def verify_static_boundary() -> dict[str, object]:
    files = [path for path in python_files() if path.resolve() != Path(__file__).resolve()]
    corpus = "\n".join(path.read_text(errors="replace") for path in files)
    banned = (
        "generativelanguage.googleapis.com",
        "GOOGLE_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_GENAI_API_KEY",
        "LAST30DAYS_REASONING_PROVIDER",
        "LAST30DAYS_PLANNER_MODEL",
        "LAST30DAYS_RERANK_MODEL",
        "from . import providers",
        "from lib.providers",
    )
    found = [token for token in banned if token in corpus]
    if found:
        raise RuntimeError(f"retired inference tokens remain: {found}")
    if (SCRIPTS / "lib/providers.py").exists():
        raise RuntimeError("retired reasoning provider module still exists")
    if list((SCRIPTS / "lib/__pycache__").glob("providers*.pyc")):
        raise RuntimeError("compiled retired reasoning provider module still exists")
    planner_ranker = (SCRIPTS / "lib/planner.py").read_text() + (SCRIPTS / "lib/rerank.py").read_text()
    if re.search(r"\b(?:XAI|OpenRouter|OPENROUTER|xai_)\b", planner_ranker):
        raise RuntimeError("retrieval provider leaked into planner/ranker")
    pipeline = (SCRIPTS / "lib/pipeline.py").read_text()
    if "xai_x.search_x" not in pipeline or "perplexity.search" not in pipeline:
        raise RuntimeError("expected retrieval-only XAI/Perplexity adapters are missing")
    return {"status": "ok", "banned_tokens": 0}


def parse_report(result: subprocess.CompletedProcess[str]) -> dict[str, object]:
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"engine exited {result.returncode}")
    report = json.loads(result.stdout)
    runtime = report.get("provider_runtime") or {}
    expected = {
        "reasoning_provider": "local",
        "planner_model": "host-plan-or-deterministic",
        "rerank_model": "deterministic-local-score",
    }
    for key, value in expected.items():
        if runtime.get(key) != value:
            raise RuntimeError(f"unexpected runtime {key}: {runtime.get(key)!r}")
    return report


def verify_engine(temp_root: Path) -> dict[str, object]:
    plan = {
        "intent": "product",
        "freshness_mode": "balanced_recent",
        "cluster_mode": "workflow",
        "source_weights": {"reddit": 1.0, "x": 1.0},
        "subqueries": [{
            "label": "workflows",
            "search_query": "OpenAI Codex workflows",
            "ranking_query": "Which OpenAI Codex workflows are useful in practice?",
            "sources": ["reddit", "x"],
            "weight": 1.0,
        }],
        "notes": ["host-verifier-plan"],
    }
    plan_path = temp_root / "plan.json"
    plan_path.write_text(json.dumps(plan))
    save_dir = temp_root / "reports"
    host = parse_report(run([
        sys.executable, str(ENGINE), "OpenAI Codex workflows", "--mock", "--quick",
        "--emit=json", "--plan", str(plan_path), "--save-dir", str(save_dir),
    ]))
    if "host-verifier-plan" not in (host.get("query_plan") or {}).get("notes", []):
        raise RuntimeError("host plan note was not preserved")
    bare = parse_report(run([
        sys.executable, str(ENGINE), "OpenAI Codex workflows", "--mock", "--quick",
        "--emit=json", "--save-dir", str(save_dir),
    ]))
    if "fallback-plan" not in (bare.get("query_plan") or {}).get("notes", []):
        raise RuntimeError("bare run did not use deterministic fallback")
    malformed = temp_root / "malformed-plan.json"
    malformed.write_text("{")
    bad = run([
        sys.executable, str(ENGINE), "OpenAI Codex", "--mock", "--emit=json",
        "--plan", str(malformed), "--save-dir", str(save_dir),
    ])
    if bad.returncode != 2 or "Invalid --plan JSON" not in bad.stderr:
        raise RuntimeError("malformed plan did not fail clearly with exit 2")
    return {
        "status": "ok",
        "host_candidates": len(host.get("ranked_candidates") or []),
        "fallback_candidates": len(bare.get("ranked_candidates") or []),
        "malformed_plan_exit": bad.returncode,
    }


def verify_host_judgments(temp_root: Path) -> dict[str, object]:
    sys.path.insert(0, str(SCRIPTS))
    import evaluate_search_quality as evaluator

    items = [{
        "key": "candidate-1",
        "source": "x",
        "sources": ["x"],
        "url": "https://example.invalid/1",
        "text": "OpenAI Codex workflow",
        "date": "2026-07-19",
    }]
    output = temp_root / "evaluation"
    empty = evaluator.get_judgments(
        output_dir=output,
        slug="openai-codex",
        topic="OpenAI Codex",
        query_type="product",
        items=items,
        judgments_dir=None,
    )
    prompt = output / "judgment-prompts/openai-codex.txt"
    if empty or not prompt.is_file():
        raise RuntimeError("host judgment prompt path failed")
    judgments = temp_root / "judgments"
    judgments.mkdir()
    (judgments / "openai-codex.json").write_text(json.dumps({
        "judgments": [{"id": "candidate-1", "grade": 3}],
    }))
    loaded = evaluator.get_judgments(
        output_dir=output,
        slug="openai-codex",
        topic="OpenAI Codex",
        query_type="product",
        items=items,
        judgments_dir=judgments,
    )
    if loaded != {"candidate-1": 3}:
        raise RuntimeError(f"host judgments were not consumed: {loaded}")
    return {"status": "ok", "prompt_written": True, "judgments_loaded": 1}


def verify_cookie_policy() -> dict[str, object]:
    result = run([sys.executable, str(SCRIPTS / "test_cookie_policy.py")])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "cookie-policy verification failed")
    return json.loads(result.stdout)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="last30days-verify-") as raw_temp:
        temp_root = Path(raw_temp)
        summary = {
            "compile": verify_compile(temp_root),
            "static_inference_boundary": verify_static_boundary(),
            "engine": verify_engine(temp_root),
            "host_judgments": verify_host_judgments(temp_root),
            "cookie_policy": verify_cookie_policy(),
        }
    print(json.dumps({"status": "ok", "checks": summary}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
