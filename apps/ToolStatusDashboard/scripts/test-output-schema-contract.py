#!/usr/bin/env python3
"""Pin the repair schemas to the model API's structured-output subset.

Every other test in this project replaces `codex` with a fake that accepts any
schema, so the one thing the API actually enforces was untested. A property
written as `{"const": 5}` shipped on 2026-08-04, the API rejected the schema with
a 400 on every call, and all 38 live repairs between then and 2026-08-07 died
before the agent ran -- while the history recorded them as ordinary unsuccessful
repairs. Approving a fix did nothing and nothing said why.

These checks are local and instant. They cannot prove the API accepts a schema,
but they do prove the rules it rejected us for are still being enforced here.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMAS = (
    HERE / "tool-status-repair-result.schema.json",
    HERE / "tool-status-repair-decision.schema.json",
)

spec = importlib.util.spec_from_file_location("worker", HERE / "tool-status-repair-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
errors_for = worker.structured_output_schema_errors

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


# 1. Every schema this project hands to the API must be clean.
for path in SCHEMAS:
    check(path.is_file(), f"{path.name} is missing")
    if not path.is_file():
        continue
    problems = errors_for(json.loads(path.read_text(encoding="utf-8")))
    check(not problems, f"{path.name} would be rejected by the API: {problems}")

# 2. The validator must still catch each rule the API actually rejected us for,
#    so it cannot rot into a function that approves everything.
REJECTED = {
    "const without type (the exact 2026-08-04 regression)": {
        "type": "object", "additionalProperties": False,
        "properties": {"schemaVersion": {"const": 5}}, "required": ["schemaVersion"],
    },
    "property omitted from required": {
        "type": "object", "additionalProperties": False,
        "properties": {"a": {"type": "string"}, "b": {"type": "string"}}, "required": ["a"],
    },
    "additionalProperties not false": {
        "type": "object", "properties": {"a": {"type": "string"}}, "required": ["a"],
    },
    "anyOf at the root": {
        "type": "object", "additionalProperties": False,
        "properties": {"a": {"type": "string"}}, "required": ["a"],
        "anyOf": [{"required": ["a"]}],
    },
    "node with no type": {
        "type": "object", "additionalProperties": False,
        "properties": {"a": {"maxLength": 5}}, "required": ["a"],
    },
    "nested object missing required": {
        "type": "object", "additionalProperties": False, "required": ["outer"],
        "properties": {"outer": {
            "type": "object", "additionalProperties": False,
            "properties": {"inner": {"type": "string"}}, "required": [],
        }},
    },
    "array without items": {
        "type": "object", "additionalProperties": False,
        "properties": {"a": {"type": "array"}}, "required": ["a"],
    },
}
for label, schema in REJECTED.items():
    check(bool(errors_for(schema)), f"validator failed to reject: {label}")

# 3. A schema that is genuinely fine must pass, or the gate blocks every build.
check(
    not errors_for({
        "type": "object", "additionalProperties": False,
        "required": ["version", "items"],
        "properties": {
            "version": {"type": "integer", "enum": [5]},
            "items": {"type": "array", "items": {"type": "string"}},
        },
    }),
    "validator rejected a conforming schema",
)

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print(f"output schema contract checks passed ({len(SCHEMAS)} shipped schemas, {len(REJECTED)} rejection rules)")
