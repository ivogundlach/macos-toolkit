#!/usr/bin/env python3
"""Regression checks for the deterministic skill audit and drift feeder."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
AUDIT = SCRIPT_DIR / "codex_skill_audit.py"
IMPROVE_SYSTEM = SKILL_DIR.parent / "improve-system"
VALIDATOR = (
    Path.home()
    / ".codex/skills/.system/skill-creator/scripts/quick_validate.py"
)
DRIFT_CHECK = Path.home() / ".local/bin/skill-drift-check"


def run(command: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


class SkillAuditTests(unittest.TestCase):
    def test_live_skills_pass_canonical_validation(self):
        for skill in (IMPROVE_SYSTEM, SKILL_DIR):
            result = run([sys.executable, str(VALIDATOR), str(skill)])
            self.assertIn("Skill is valid", result.stdout)

    def test_inventory_reports_only_evidence_backed_fixture_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "skills"
            good = root / "workflow" / "good-skill"
            bad = root / "workflow" / "bad-skill"
            (good / "agents").mkdir(parents=True)
            (good / "scripts").mkdir()
            (bad / "agents").mkdir(parents=True)
            (bad / "scripts").mkdir()

            (good / "SKILL.md").write_text(
                "---\nname: good-skill\ndescription: Use when a good fixture is needed.\n---\n"
                "# Good\nA generic $skill placeholder is not a concrete dependency.\n",
                encoding="utf-8",
            )
            (good / "agents/openai.yaml").write_text(
                'interface:\n  default_prompt: "Use $good-skill for the fixture."\n',
                encoding="utf-8",
            )
            executable = good / "scripts/run.py"
            executable.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
            executable.chmod(0o755)

            (bad / "SKILL.md").write_text(
                "---\nname: bad-skill\ndescription: Generic fixture helper.\n"
                "arguments:\n  path: fixture\n---\n# Bad\nUse $missing-skill.\n",
                encoding="utf-8",
            )
            (bad / "agents/openai.yaml").write_text(
                'interface:\n  default_prompt: "Run the fixture."\n', encoding="utf-8"
            )
            (bad / "scripts/not-executable.py").write_text(
                "#!/usr/bin/env python3\n", encoding="utf-8"
            )
            (bad / ".DS_Store").write_bytes(b"fixture")

            result = run(
                [sys.executable, str(AUDIT), "skills", "--root", str(root), "--json"]
            )
            payload = json.loads(result.stdout)
            rows = {row["name"]: row for row in payload["skills"]}
            self.assertEqual(rows["good-skill"]["flags"], [])
            flags = set(rows["bad-skill"]["flags"])
            self.assertTrue(
                {
                    "description_summary",
                    "extraneous_artifact",
                    "forbidden_frontmatter",
                    "openai_prompt_missing_skill_invocation",
                    "script_not_executable",
                    "stale_skill_reference",
                }.issubset(flags)
            )
            self.assertEqual(rows["bad-skill"]["forbidden_frontmatter_keys"], ["arguments"])

            missing = subprocess.run(
                [sys.executable, str(AUDIT), "skills", "--root", str(root / "missing"), "--json"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("skill root does not exist", missing.stderr)

    def test_drift_feeder_is_read_only_until_explicit_refresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audit = root / "audit.py"
            miner = root / "miner.py"
            state = root / "state"
            audit.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os\n"
                "flags=json.loads(os.environ.get('AUDIT_FLAGS', '[]'))\n"
                "rel=os.environ.get('AUDIT_REL', 'workflow/good-skill')\n"
                "print(json.dumps({'skills':[{'name':'good-skill','rel':rel,"
                "'description_class':{'label':'TRIGGER'},'flags':flags}]}))\n",
                encoding="utf-8",
            )
            miner.write_text(
                "#!/usr/bin/env python3\n"
                "import os\n"
                "print('# scriptify candidates')\n"
                "print('sess  days  runs  source  pattern')\n"
                "pattern=os.environ.get('MINER_PATTERN')\n"
                "if pattern: print(f'3  2  15  codex  {pattern}')\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update(
                {
                    "SKILL_AUDIT_SCRIPT": str(audit),
                    "SCRIPTIFY_MINER": str(miner),
                    "SKILL_DRIFT_STATE": str(state),
                    "CODEX_SKILLS_ROOT": str(root / "skills"),
                }
            )
            first_check = run([sys.executable, str(DRIFT_CHECK), "--check"], env=env)
            self.assertIn("No compatible baseline", first_check.stdout)
            self.assertFalse(state.exists())

            run([sys.executable, str(DRIFT_CHECK), "--refresh"], env=env)
            self.assertFalse((state / "report.md").exists())
            baseline = (state / "last-audit.json").read_text(encoding="utf-8")

            env["MINER_PATTERN"] = "build.sh"
            env["AUDIT_REL"] = "tool/good-skill"
            env["AUDIT_FLAGS"] = '["description_summary"]'
            changed = run([sys.executable, str(DRIFT_CHECK), "--check"], env=env)
            self.assertIn("moved from `workflow/good-skill` to `tool/good-skill`", changed.stdout)
            self.assertIn("added audit flags: ['description_summary']", changed.stdout)
            self.assertIn("NEW repeated command pattern `build.sh`", changed.stdout)
            self.assertEqual((state / "last-audit.json").read_text(encoding="utf-8"), baseline)
            self.assertFalse((state / "report.md").exists())

            run([sys.executable, str(DRIFT_CHECK), "--report"], env=env)
            report = (state / "report.md").read_text(encoding="utf-8")
            self.assertIn("`build.sh` (15 runs in 14d)", report)
            self.assertNotIn("[ ]", report)

            run([sys.executable, str(DRIFT_CHECK), "--refresh"], env=env)
            self.assertFalse((state / "report.md").exists())

            env.pop("MINER_PATTERN")
            env["AUDIT_FLAGS"] = "[]"
            resolved = run([sys.executable, str(DRIFT_CHECK), "--check"], env=env)
            self.assertIn("resolved audit flags: ['description_summary']", resolved.stdout)
            self.assertIn("disappeared from the candidate set", resolved.stdout)


if __name__ == "__main__":
    unittest.main()
