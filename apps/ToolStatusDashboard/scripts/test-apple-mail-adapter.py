#!/usr/bin/env python3
"""Isolated Tool Status Dashboard contract test for Apple Mail draft failures."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from pathlib import Path


SCANNER = Path(os.environ.get("TOOL_STATUS_SCANNER_UNDER_TEST", Path(__file__).with_name("tool-status-scan.py")))


def main() -> int:
    spec = importlib.util.spec_from_file_location("tool_status_scan_mail_test", SCANNER)
    assert spec and spec.loader
    scanner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scanner)

    with tempfile.TemporaryDirectory(prefix="tool-status-mail-adapter-") as temporary:
        scanner.HOME = Path(temporary)
        state_path = scanner.HOME / ".local/state/inbound-response-drafter/state.json"
        state_path.parent.mkdir(parents=True)
        state_path.write_text(json.dumps({
            "messages": {
                "rfc:<ambiguous@example.com>": {
                    "status": "failed-permanent",
                    "phase": "manual-review",
                    "reason": "draft save outcome is ambiguous",
                    "updated_at": 100,
                }
            }
        }), encoding="utf-8")
        rows: list[dict] = []
        scanner.operational_failure_records(rows)
        record = next(row for row in rows if row["id"] == "Background Job:Apple Mail Draft Assistant Health")
        assert record["state"] == "fail", record
        assert record["causeCode"] == "apple_mail_draft.failed", record
        assert record["notificationPolicy"] == "immediate", record
        assert "[manual-review]" in record["detail"], record
        assert record["causeParams"]["manual_review_count"] == "1", record
        assert "inspect Apple Mail Drafts" in record["fix"]["note"], record

        state_path.write_text("{not-json", encoding="utf-8")
        rows = []
        scanner.operational_failure_records(rows)
        record = next(row for row in rows if row["id"] == "Background Job:Apple Mail Draft Assistant Health")
        assert record["state"] == "fail", record
        assert record["causeCode"] == "apple_mail_draft.state_unreadable", record
        assert record["notificationPolicy"] == "immediate", record
        assert "state unreadable" in record["headline"].lower(), record
        assert "repair or restore state.json" in record["fix"]["note"], record

    print("Apple Mail Dashboard adapter checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
