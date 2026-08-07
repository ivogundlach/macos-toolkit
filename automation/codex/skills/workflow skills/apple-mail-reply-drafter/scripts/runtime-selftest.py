#!/usr/bin/env python3
"""Offline regression checks for the installed Apple Mail draft runtime."""

from __future__ import annotations

import importlib.util
import importlib.machinery
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path


HOME = Path.home()
HELPER_PATH = HOME / ".local/bin/apple-mail-draft-assistant"
RUNNER_PATH = HOME / ".local/bin/apple-mail-draft-runner"


def load_helper():
    module_name = "apple_mail_draft_assistant_runtime"
    loader = importlib.machinery.SourceFileLoader(module_name, str(HELPER_PATH))
    spec = importlib.util.spec_from_loader(module_name, loader)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class RuntimeStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.helper = load_helper()
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.helper.STATE_DIR = root
        self.helper.STATE_FILE = root / "state.json"
        self.helper.FAILURES_FILE = root / "failures.jsonl"
        self.helper.LOCK_FILE = root / "state.lock"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def state_record(self, key: str) -> dict:
        return json.loads(self.helper.STATE_FILE.read_text(encoding="utf-8"))["messages"][key]

    def test_generation_failure_retries_once_then_becomes_permanent(self) -> None:
        key = "rfc:<retry@example.com>"
        self.assertTrue(self.helper.claim_state(key, "op-1")["claimed"])
        first = self.helper.mark_state(key, "failed", "first")
        self.assertEqual(first["status"], "failed")
        self.assertEqual(first["attempts"], 1)
        self.assertTrue(self.helper.claim_state(key, "op-2")["claimed"])
        second = self.helper.mark_state(key, "failed", "second")
        self.assertEqual(second["status"], "failed-permanent")
        self.assertEqual(second["attempts"], 2)
        preserved = self.helper.mark_state(key, "failed", "must-not-downgrade")
        self.assertEqual(preserved["status"], "failed-permanent")

    def test_active_creating_state_never_reclaims_even_with_same_operation(self) -> None:
        key = "rfc:<creating@example.com>"
        self.helper.claim_state(key, "op-1")
        self.helper.transition_to_creating(key, "op-1", {"mail_id": 1})
        result = self.helper.claim_state(key, "op-1")
        self.assertFalse(result["claimed"])
        self.assertEqual(result["reason"], "active-mail-save")

    def test_stale_creating_state_requires_manual_review(self) -> None:
        key = "rfc:<stale@example.com>"
        self.helper.claim_state(key, "op-1")
        self.helper.transition_to_creating(key, "op-1", {"mail_id": 1})
        state = json.loads(self.helper.STATE_FILE.read_text(encoding="utf-8"))
        state["messages"][key]["updated_at"] = int(time.time()) - self.helper.CLAIM_STALE_SECONDS - 1
        self.helper.save_state(state)
        result = self.helper.claim_state(key, "op-2")
        self.assertFalse(result["claimed"])
        record = self.state_record(key)
        self.assertEqual(record["status"], "failed-permanent")
        self.assertEqual(record["phase"], "manual-review")

    def test_legacy_fallback_state_fails_closed(self) -> None:
        self.helper.ensure_state_dir()
        self.helper.STATE_FILE.write_text(
            json.dumps({"messages": {"fallback:old": {"status": "drafted"}}}),
            encoding="utf-8",
        )
        with self.assertRaises(SystemExit):
            self.helper.load_state()

    def test_message_without_rfc_id_uses_mime_content_identity(self) -> None:
        first = self.helper.state_key_for_fields(
            "apple-mail://inbox", 1, "person@example.com", "Hello", {},
            "From: person@example.com\nSubject: Hello\n\nFirst body",
        )
        same = self.helper.state_key_for_fields(
            "apple-mail://other", 999, "person@example.com", "Hello", {},
            "From: person@example.com\nSubject: Hello\n\nFirst body",
        )
        different = self.helper.state_key_for_fields(
            "apple-mail://inbox", 1, "person@example.com", "Hello", {},
            "From: person@example.com\nSubject: Hello\n\nDifferent body",
        )
        self.assertTrue(first.startswith("mime:"))
        self.assertEqual(first, same)
        self.assertNotEqual(first, different)


class RuntimeContractTests(unittest.TestCase):
    def test_runner_model_and_canonical_rules(self) -> None:
        runner = RUNNER_PATH.read_text(encoding="utf-8")
        self.assertIn('"gpt-5.6-terra"', runner)
        self.assertIn('model_reasoning_effort="medium"', runner)
        self.assertIn("load_correspondence_rules()", runner)
        self.assertNotIn("gpt-5.6-luna", runner)

    def test_junk_read_happens_before_delete(self) -> None:
        helper = load_helper()
        normalized = " ".join(helper.JUNK_READ_DELETE_APPLESCRIPT.lower().split())
        self.assertLess(normalized.index("set read status of m to true"), normalized.index("delete m"))

    def test_junk_mailbox_enumeration_fails_closed_on_malformed_output(self) -> None:
        helper = load_helper()
        valid = helper.parse_junk_mailbox_refs("iCloud\x1fJunk\x1f12,34\x1e")
        self.assertEqual(valid, [("iCloud", "Junk", [12, 34])])
        for malformed in (
            "iCloud\x1fJunk\x1e",
            "iCloud\x1fJunk\x1f12,nope\x1e",
            "\x1fJunk\x1f12\x1e",
        ):
            with self.assertRaises(RuntimeError):
                helper.parse_junk_mailbox_refs(malformed)

    def test_saved_reply_recipients_must_match_exactly(self) -> None:
        helper = load_helper()
        helper.require_exact_saved_recipients(
            "person@example.com\n", {"person@example.com"}, "reply"
        )
        with self.assertRaises(RuntimeError):
            helper.require_exact_saved_recipients(
                "person@example.com\nunexpected@example.com\n",
                {"person@example.com"},
                "reply",
            )

    def test_reply_state_key_must_match_source_identity(self) -> None:
        helper = load_helper()
        helper.validate_source_state_key("rfc:<message@example.com>", "<message@example.com>")
        helper.validate_source_state_key("mime:" + "a" * 64, "")
        with self.assertRaises(RuntimeError):
            helper.validate_source_state_key("rfc:<different@example.com>", "<message@example.com>")
        with self.assertRaises(RuntimeError):
            helper.validate_source_state_key("arbitrary-key", "")

    def test_non_ascii_junk_text_is_not_treated_as_blank(self) -> None:
        helper = load_helper()
        for body in ("你好", "Привет", "مرحبا", "🙂", "—"):
            self.assertTrue(helper.has_meaningful_text(body), body)
        for body in ("", " \n\t", "\u200b\ufffc"):
            self.assertFalse(helper.has_meaningful_text(body), repr(body))

    def test_both_draft_scripts_are_send_free(self) -> None:
        helper = load_helper()
        import re
        for script in (
            helper.REPLY_APPLESCRIPT,
            helper.MESSAGE_DRAFT_APPLESCRIPT,
            helper.ADD_MESSAGE_DRAFT_ATTACHMENTS_APPLESCRIPT,
        ):
            self.assertIsNone(re.search(r"(?i)\bsend\b", script))

    def test_attachment_paths_require_readable_nonempty_files(self) -> None:
        helper = load_helper()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            valid = root / "proof with spaces.png"
            valid.write_bytes(b"proof")
            self.assertEqual(helper.validated_attachment_paths([str(valid)]), [str(valid.resolve())])
            with self.assertRaises(SystemExit):
                helper.validated_attachment_paths([str(root / "missing.png")])
            with self.assertRaises(SystemExit):
                helper.validated_attachment_paths([str(root)])
            empty = root / "empty.png"
            empty.write_bytes(b"")
            with self.assertRaises(SystemExit):
                helper.validated_attachment_paths([str(empty)])

    def test_reported_attachment_paths_must_cover_requested_files(self) -> None:
        helper = load_helper()
        expected = [str(Path("/tmp/proof.png").resolve())]
        self.assertEqual(
            helper.require_reported_attachment_paths("/tmp/proof.png\n", expected),
            expected,
        )
        with self.assertRaises(RuntimeError):
            helper.require_reported_attachment_paths("", expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
