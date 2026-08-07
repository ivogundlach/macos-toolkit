#!/usr/bin/env python3
"""Focused deterministic tests for the Exa CLI."""

from __future__ import annotations

import importlib.util
import json
import os
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("exa_cli.py")
SPEC = importlib.util.spec_from_file_location("exa_cli", MODULE_PATH)
exa_cli = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(exa_cli)


class FakeResponse:
    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, amount):
        return self.payload[:amount]


class ExaCliTests(unittest.TestCase):
    def test_missing_credentials_is_actionable(self):
        with mock.patch.dict(os.environ, {"EXA_API_KEY": ""}, clear=False), mock.patch.object(exa_cli, "_keychain_value", return_value=None):
            with self.assertRaises(exa_cli.ExaError) as caught:
                exa_cli.require_key()
        self.assertEqual(caught.exception.kind, "missing_credentials")
        self.assertIn("auth-store", caught.exception.repair)

    def test_environment_wins_and_difference_is_reported(self):
        with mock.patch.dict(os.environ, {"EXA_API_KEY": "env-secret"}, clear=False), mock.patch.object(exa_cli, "_keychain_value", return_value="other-secret"):
            key, source, warnings = exa_cli.credential()
        self.assertEqual((key, source), ("env-secret", "environment"))
        self.assertTrue(warnings)

    def test_transient_network_failure_retries_once(self):
        failure = urllib.error.URLError("temporary")
        success = FakeResponse({"requestId": "r1", "results": []})
        with mock.patch.object(exa_cli.urllib.request, "urlopen", side_effect=[failure, success]) as opened, mock.patch.object(exa_cli.time, "sleep"):
            payload, attempts = exa_cli.api_request(
                "search", {"query": "x"}, "secret", timeout=1,
                max_bytes=10_000, attempts=2,
            )
        self.assertEqual(payload["requestId"], "r1")
        self.assertEqual(attempts, 2)
        self.assertEqual(opened.call_count, 2)

    def test_key_is_redacted(self):
        rendered = exa_cli._redact("failure secret-value Authorization: BearerThing", "secret-value")
        self.assertNotIn("secret-value", rendered)
        self.assertNotIn("BearerThing", rendered)

    def test_visible_raw_output_is_rejected(self):
        with self.assertRaises(exa_cli.ExaError) as caught:
            exa_cli.emit({"ok": True}, Path.home() / "Downloads" / "would-be-raw.json")
        self.assertEqual(caught.exception.kind, "visible_output_rejected")

    def test_partial_contents_failure_is_not_silent(self):
        args = mock.Mock(
            urls=["https://example.com/a", "https://example.com/b"], mode="text",
            max_characters=1000, highlights_query=None, fresh=False, subpages=0,
            subpage_target=[], timeout=1, max_bytes=10_000, attempts=1,
        )
        response = {
            "results": [{"url": args.urls[0], "text": "ok"}],
            "statuses": [
                {"id": args.urls[0], "status": "success"},
                {"id": args.urls[1], "status": "CRAWL_NOT_FOUND"},
            ],
        }
        with mock.patch.object(exa_cli, "require_key", return_value=("secret", "environment", [])), mock.patch.object(exa_cli, "api_request", return_value=(response, 1)):
            with self.assertRaises(exa_cli.ExaError) as caught:
                exa_cli.command_contents(args)
        self.assertEqual(caught.exception.kind, "partial_content_failure")

    def test_auth_store_sends_key_over_stdin_not_argv(self):
        completed = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.dict(os.environ, {"EXA_API_KEY": "secret-value", "USER": "ivo"}, clear=False), mock.patch.object(exa_cli.subprocess, "run", return_value=completed) as invoked:
            result = exa_cli.command_auth_store(mock.Mock())
        command = invoked.call_args.args[0]
        self.assertNotIn("secret-value", command)
        self.assertEqual(invoked.call_args.kwargs["input"], "secret-value\n")
        self.assertTrue(result["ok"])


if __name__ == "__main__":
    unittest.main()
