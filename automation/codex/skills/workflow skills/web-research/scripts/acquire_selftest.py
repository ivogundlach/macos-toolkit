#!/usr/bin/env python3
"""Focused deterministic tests for the public acquisition router."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("acquire_url.py")
SPEC = importlib.util.spec_from_file_location("acquire_url", MODULE_PATH)
acquire_url = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(acquire_url)


def args_for(url: str, output: Path) -> argparse.Namespace:
    return argparse.Namespace(
        url=url, output_dir=output, timeout=1.0, max_bytes=100_000,
        max_characters=10_000, max_redirects=2, attempt_budget=3,
        keep_days=14, skip_exa=False, skip_firecrawl=False,
    )


class AcquireTests(unittest.TestCase):
    def test_raw_assessment_rejects_access_wall(self):
        with tempfile.TemporaryDirectory() as directory:
            text = Path(directory) / "text.txt"
            text.write_text("Sign in to continue " + ("placeholder " * 20), encoding="utf-8")
            metadata = {"status": 200, "content_type": "text/html", "body_bytes": 5000, "text_extracted": True}
            usable, reason = acquire_url.raw_assessment(metadata, text)
        self.assertFalse(usable)
        self.assertEqual(reason, "delivery_or_access_wall")

    def test_route_falls_through_raw_and_exa_to_firecrawl(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"

            def fake_fetch(url, raw_dir, *unused):
                raw_dir.mkdir(parents=True)
                (raw_dir / "text.txt").write_text("loading", encoding="utf-8")
                return {"status": 200, "content_type": "text/html", "body_bytes": 5000, "text_extracted": True, "likely_client_rendered_shell": True}

            def fake_command(command, timeout):
                target = Path(command[command.index("--output") + 1])
                if "exa_cli.py" in command[1]:
                    return subprocess.CompletedProcess(command, 5, "", '{"ok":false,"kind":"http_error"}')
                target.write_text(json.dumps({"markdown": "usable evidence " * 20, "links": []}), encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch.object(acquire_url.fetch_url, "fetch", side_effect=fake_fetch), mock.patch.object(acquire_url, "run_command", side_effect=fake_command):
                manifest, code = acquire_url.acquire(args_for("https://example.com", output))
        self.assertEqual(code, 0)
        self.assertEqual(manifest["selected_method"], "firecrawl")
        self.assertEqual([item["method"] for item in manifest["attempts"]], ["raw", "exa", "firecrawl"])
        self.assertTrue(manifest["notify_user"])

    def test_terminal_failure_names_next_path(self):
        manifest = acquire_url.terminal_manifest(
            url="https://example.com", output=Path("/tmp/x"),
            attempts=[{"method": "raw", "ok": False, "reason": "access_control_http_403"}],
            selected=None, selected_evidence=None, raw_reason="access_control_http_403", keep_days=14,
        )
        self.assertFalse(manifest["ok"])
        self.assertEqual(manifest["next_path"], "authenticated_browser")
        self.assertTrue(manifest["notify_user"])

    def test_dns_failure_does_not_recommend_browser(self):
        manifest = acquire_url.terminal_manifest(
            url="https://missing.invalid", output=Path("/tmp/x"),
            attempts=[{"method": "raw", "ok": False, "reason": "raw_exception:FetchError", "detail": "DNS resolution failed for missing.invalid"}],
            selected=None, selected_evidence=None, raw_reason="raw_exception:FetchError", keep_days=14,
        )
        self.assertEqual(manifest["next_path"], "repair_url_or_dns")
        self.assertIn("browser escalation cannot repair", manifest["repair"])

    def test_all_provider_failures_are_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"

            def failed_fetch(*unused):
                raise acquire_url.fetch_url.FetchError("temporary raw failure")

            failed_command = subprocess.CompletedProcess(["provider"], 5, "", "provider unavailable")
            with mock.patch.object(acquire_url.fetch_url, "fetch", side_effect=failed_fetch), mock.patch.object(acquire_url, "run_command", return_value=failed_command):
                manifest, code = acquire_url.acquire(args_for("https://example.com", output))
        self.assertEqual(code, 1)
        self.assertEqual([item["method"] for item in manifest["attempts"]], ["raw", "exa", "firecrawl"])
        self.assertIn("Attempted: raw, exa, firecrawl", manifest["notification"])
        self.assertTrue(manifest["notify_user"])

    def test_retention_prunes_only_owned_completed_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            owned = root / "20200101T000000-0123456789"
            incomplete = root / "20200101T000000-abcdef0123"
            unrelated = root / "user-data"
            owned.mkdir()
            incomplete.mkdir()
            unrelated.mkdir()
            (owned / "manifest.json").write_text("{}", encoding="utf-8")
            old = time.time() - 30 * 86400
            os.utime(owned, (old, old))
            os.utime(incomplete, (old, old))
            os.utime(unrelated, (old, old))
            acquire_url.prune_owned(root, keep_days=14)
            self.assertFalse(owned.exists())
            self.assertTrue(incomplete.exists())
            self.assertTrue(unrelated.exists())


if __name__ == "__main__":
    unittest.main()
