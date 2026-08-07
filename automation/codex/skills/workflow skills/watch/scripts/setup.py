#!/usr/bin/env python3
"""Deterministic watch diagnostics and keyless configuration initialization."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from config import init_config, preflight  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect or initialize watch configuration.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--json", action="store_true", help="Print structured status")
    group.add_argument("--check", action="store_true", help="Silent dependency/config check")
    group.add_argument("--init", action="store_true", help="Create a keyless 0600 config")
    args = parser.parse_args()

    if args.init or (not args.json and not args.check):
        path, created = init_config()
        result = preflight()
        result["config_created"] = created
        print(json.dumps(result, indent=2))
        return 0 if result["can_proceed"] else 2

    result = preflight()
    if args.json:
        print(json.dumps(result, indent=2))
    elif not result["can_proceed"]:
        print(
            f"watch preflight failed: {result['repair_action'] or 'inspect structured status'}",
            file=sys.stderr,
        )
    return 0 if result["can_proceed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
