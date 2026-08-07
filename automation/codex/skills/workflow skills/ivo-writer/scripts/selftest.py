#!/usr/bin/env python3
"""Synthetic regression tests for ivo-writer's local draft checker."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SKILL_ROOT = ROOT.parent
CHECKER = ROOT / "check-draft.py"
IVO_WRITER_SKILL = SKILL_ROOT / "SKILL.md"
CORRESPONDENCE = SKILL_ROOT / "references/correspondence.md"
APPLE_MAIL_SKILL = SKILL_ROOT.parent / "apple-mail-reply-drafter" / "SKILL.md"
PYTHON = Path("/usr/bin/python3")
EXPECTED_ERROR_CODES = {
    "banned_lexicon",
    "banned_starter",
    "banned_cliche",
    "smart_quotes",
    "assistant_residue",
    "todo_marker",
    "bracket_placeholder",
    "manual_ivo_signature",
}
EXPECTED_EVENT_CODES = {
    "exact_triad",
    "participle_tail",
    "negative_parallelism",
    "canned_conclusion",
    "false_range",
}


def invoke(text: str, *args: str) -> tuple[subprocess.CompletedProcess[str], dict]:
    proc = subprocess.run(
        [str(PYTHON), str(CHECKER), *args],
        input=text,
        text=True,
        capture_output=True,
        check=False,
    )
    return proc, json.loads(proc.stdout)


def codes(payload: dict) -> set[str]:
    return {item["code"] for item in payload.get("findings", [])}


class CheckerTests(unittest.TestCase):
    def test_schema_and_rule_codes_are_pinned(self) -> None:
        spec = importlib.util.spec_from_file_location("ivo_writer_checker_schema", CHECKER)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        self.assertEqual(module.SCHEMA_VERSION, 2)
        self.assertEqual(module.ERROR_CODES, EXPECTED_ERROR_CODES)
        self.assertEqual(module.EVENT_CODES, EXPECTED_EVENT_CODES)

    def test_clean_correspondence_passes(self) -> None:
        proc, payload = invoke(
            "Jordan,\n\nThe timing works for me. I can meet Thursday after 14:00.\n\nBest,\n",
            "--mode", "correspondence",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["status"], "pass")
        self.assertFalse(payload["detector_analysis"]["enabled"])

    def test_clean_general_document_disables_detector_events(self) -> None:
        proc, payload = invoke(
            "The room was cold, quiet, and empty. The observation belongs in my notes.",
            "--mode", "document",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["status"], "pass")
        self.assertEqual(payload["detector_analysis"]["events_considered"], 0)

    def test_attestations_must_be_separate_and_complete(self) -> None:
        for flag in ("--assert-authorship", "--assert-non-assessed"):
            with self.subTest(flag=flag):
                proc, payload = invoke("My notes.", "--mode", "document", flag)
                self.assertEqual(proc.returncode, 2)
                self.assertEqual(payload["error"]["code"], "invalid_invocation")

    def test_correspondence_rejects_detector_attestations(self) -> None:
        proc, payload = invoke(
            "My note.",
            "--mode", "correspondence",
            "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(payload["status"], "error")

    def test_each_error_rule_is_emitted(self) -> None:
        cases = {
            "banned_lexicon": ("This is a robust claim.", "document"),
            "banned_starter": ("Moreover, the claim fails.", "document"),
            "banned_cliche": ("This stands as a reminder of the cost.", "document"),
            "smart_quotes": ("He called it “wrong.”", "document"),
            "assistant_residue": ("Here is the draft you requested.", "document"),
            "todo_marker": ("TODO: confirm the date.", "document"),
            "bracket_placeholder": ("Call them on [add date].", "document"),
            "manual_ivo_signature": ("Jordan,\n\nThat works.\n\nBest,\nIvo\n", "correspondence"),
        }
        for expected, (text, mode) in cases.items():
            with self.subTest(code=expected):
                proc, payload = invoke(text, "--mode", mode)
                self.assertEqual(proc.returncode, 1)
                self.assertIn(expected, codes(payload))

    def test_quoted_reply_signature_is_not_flagged(self) -> None:
        proc, payload = invoke(
            "Jordan,\n\nThat works.\n\n> Best,\n> Ivo\n",
            "--mode", "correspondence",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("manual_ivo_signature", codes(payload))

    def test_one_triad_is_suppressed(self) -> None:
        proc, payload = invoke(
            "The room was cold, quiet, and empty.",
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["detector_analysis"]["suppressed_event_count"], 1)
        self.assertNotIn("style_cluster", codes(payload))

    def test_different_events_on_same_line_cluster(self) -> None:
        proc, payload = invoke(
            "It is not simple, but rather difficult, creating a problem.",
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("style_cluster", codes(payload))

    def test_duplicate_same_rule_on_one_line_does_not_cluster(self) -> None:
        proc, payload = invoke(
            "The room was cold, quiet, and empty; the hall felt dark, still, and bare.",
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("style_cluster", codes(payload))
        self.assertEqual(payload["detector_analysis"]["events_considered"], 1)

    def test_eight_line_span_clusters(self) -> None:
        lines = ["The room was cold, quiet, and empty."] + ["Plain note."] * 6 + [
            "It is not simple, but rather difficult."
        ]
        proc, payload = invoke(
            "\n".join(lines),
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("style_cluster", codes(payload))

    def test_nine_line_span_does_not_cluster(self) -> None:
        lines = ["The room was cold, quiet, and empty."] + ["Plain note."] * 7 + [
            "It is not simple, but rather difficult."
        ]
        proc, payload = invoke(
            "\n".join(lines),
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["detector_analysis"]["suppressed_event_count"], 2)

    def test_greedy_lines_one_eight_fifteen(self) -> None:
        lines = ["Plain note."] * 15
        lines[0] = "The room was cold, quiet, and empty."
        lines[7] = "It is not simple, but rather difficult."
        lines[14] = "From policy to private memory, the note keeps moving."
        proc, payload = invoke(
            "\n".join(lines),
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(sum(item["code"] == "style_cluster" for item in payload["findings"]), 1)
        self.assertEqual(payload["detector_analysis"]["suppressed_event_count"], 1)

    def test_ignore_applies_before_clustering(self) -> None:
        proc, payload = invoke(
            "It is not simple, but rather difficult, creating a problem.",
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
            "--ignore-rule", "participle_tail",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("style_cluster", codes(payload))
        self.assertEqual(payload["detector_analysis"]["suppressed_event_count"], 1)

    def test_default_json_does_not_echo_source(self) -> None:
        source = "privatecanary-4M7Z robust phrase"
        proc, payload = invoke(source, "--mode", "document")
        self.assertEqual(proc.returncode, 1)
        serialized = json.dumps(payload)
        self.assertNotIn("privatecanary-4M7Z", serialized)
        self.assertNotIn("snippet", serialized)
        self.assertIn("No source excerpts", payload["privacy_note"])

    def test_snippets_are_explicit_opt_in(self) -> None:
        proc, payload = invoke(
            "This is a robust phrase.", "--mode", "document", "--show-snippets"
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("snippet", payload["findings"][0])
        self.assertIn("source excerpts are included", payload["privacy_note"])

    def test_empty_stdin_passes(self) -> None:
        proc, payload = invoke("", "--mode", "document")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["status"], "pass")

    def test_invalid_utf8_is_structured_exit_two(self) -> None:
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(b"\xff\xfe")
            handle.flush()
            proc = subprocess.run(
                [str(PYTHON), str(CHECKER), "--mode", "document", "--file", handle.name],
                text=True,
                capture_output=True,
                check=False,
            )
        payload = json.loads(proc.stdout)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(payload["error"]["code"], "invalid_invocation")

    def test_long_line_column_is_one_based_unicode(self) -> None:
        proc, payload = invoke("a" * 10000 + " robust", "--mode", "document")
        self.assertEqual(proc.returncode, 1)
        target = next(item for item in payload["findings"] if item["code"] == "banned_lexicon")
        self.assertEqual(target["line"], 1)
        self.assertEqual(target["column"], 10002)

    def test_unknown_rule_is_exit_two(self) -> None:
        proc, payload = invoke(
            "Plain note.", "--mode", "document", "--ignore-rule", "missing_rule"
        )
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(payload["status"], "error")

    def test_unexpected_exception_is_structured_exit_three(self) -> None:
        spec = importlib.util.spec_from_file_location("ivo_writer_checker_internal", CHECKER)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        original = module.analyze

        def fail(**_kwargs):
            raise RuntimeError("synthetic internal canary")

        module.analyze = fail
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
            handle.write("Plain note.")
            handle.flush()
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                rc = module.main(["--mode", "document", "--file", handle.name])
        module.analyze = original
        payload = json.loads(output.getvalue())
        self.assertEqual(rc, 3)
        self.assertEqual(payload["error"]["code"], "internal_error")

    def test_detector_json_labels_unverified_attestations(self) -> None:
        proc, payload = invoke(
            "My plain personal note.",
            "--mode", "document", "--assert-authorship", "--assert-non-assessed",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(payload["asserted_authorship"])
        self.assertTrue(payload["asserted_non_assessed"])
        self.assertTrue(payload["detector_analysis"]["enabled"])
        self.assertIn("unverified", payload["disclaimer"])


class AppleMailCompatibilityTests(unittest.TestCase):
    def test_correspondence_markers_match_runner_smoke_contract(self) -> None:
        home = Path.home().resolve()
        override = os.environ.get("IVO_WRITER_APPLE_MAIL_RUNNER")
        candidate = Path(override).expanduser() if override else home / ".local/bin/apple-mail-draft-runner"
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError:
            print("compatibility_status=skipped reason=runner_absent")
            return
        try:
            resolved.relative_to(home)
        except ValueError:
            print("compatibility_status=needs_review reason=runner_outside_home")
            return
        runner = resolved.read_text(encoding="utf-8", errors="strict")
        reference = CORRESPONDENCE.read_text(encoding="utf-8")
        markers = (
            "neutral-polished",
            "Short does not mean incomplete",
            "multiple small asks",
            'do not add "Ivo"',
        )
        wiring = (
            "CORRESPONDENCE_PATH",
            "references\" / \"correspondence.md",
            "load_correspondence_rules()",
        )
        missing = [marker for marker in markers if marker not in reference]
        missing.extend(token for token in wiring if token not in runner)
        if missing:
            print("compatibility_status=needs_review reason=marker_mismatch")
        self.assertEqual(missing, [])
        print("compatibility_status=pass")


class DocumentationIntegrityTests(unittest.TestCase):
    def test_target_language_gate_is_present_in_canonical_docs(self) -> None:
        correspondence = CORRESPONDENCE.read_text(encoding="utf-8")
        ivo_writer = IVO_WRITER_SKILL.read_text(encoding="utf-8")
        apple_mail = APPLE_MAIL_SKILL.read_text(encoding="utf-8")

        target_gate = "## Target-language gate"
        self.assertIn(target_gate, correspondence)
        gate_start = correspondence.index(target_gate) + len(target_gate)
        next_heading = correspondence.find("\n## ", gate_start)
        self.assertNotEqual(next_heading, -1)
        gate_body = correspondence[gate_start:next_heading]
        self.assertEqual(sum(line.startswith("- ") for line in gate_body.splitlines()), 6)
        self.assertIn("is not evidence", correspondence)
        self.assertIn("established language of the inspected case/thread as a whole", correspondence)
        self.assertIn("requires asking before draft creation", correspondence)
        self.assertIn("formal Sie", correspondence)
        self.assertIn("never recreate a draft with attachments or user edits", correspondence)
        self.assertIn(
            "Ivo's instruction language is not the target language unless he explicitly names the draft language.",
            ivo_writer,
        )
        self.assertIn("## Target-language gate", ivo_writer)
        self.assertLess(ivo_writer.index("## Target-language gate"), ivo_writer.index("## Select the mode"))
        self.assertIn("declare `Target language:", apple_mail)
        self.assertIn(
            "Ivo's instruction language is not evidence unless he explicitly names the draft language",
            apple_mail,
        )
        self.assertIn("verify the full human-authored text before creation", apple_mail)
        self.assertIn("references/correspondence.md", apple_mail)
        self.assertNotIn("- Match the incoming message language.", correspondence)
        self.assertNotIn("- Match the message language when obvious.", apple_mail)


if __name__ == "__main__":
    unittest.main(verbosity=2)
