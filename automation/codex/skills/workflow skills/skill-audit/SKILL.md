---
name: skill-audit
description: >-
  Use when Ivo asks to run, inspect, or discuss the full skill audit, weekly
  skill audit, every-skill evaluation, skill drift, or the report produced by
  skill-drift-check. Audit the canonical skill corpus with deterministic
  inventory evidence, inspect only supported findings, check trigger quality
  and cross-skill wiring, and propose concrete corrections without editing
  until the global approval contract authorizes them. Use skill-creator for one
  skill and improve-system for lessons from the current session.
---

# Skill Audit

Audit the full canonical skill corpus on demand. This is a corpus-wide sweep;
it does not replace `skill-creator` for one skill or `improve-system` for the
current session.

Resolve the bundled script from the directory containing the loaded `SKILL.md`;
do not assume the process is already running from that directory. This keeps
canonical category folders and flattened generated mirrors working.

## Procedure

1. Set `SKILL_DIR` to the directory containing the loaded `SKILL.md`, then run
   the bundled deterministic inventory:

   ```bash
   python3 "$SKILL_DIR/scripts/codex_skill_audit.py" skills --root "${CODEX_HOME:-$HOME/.codex}/skills" --json
   ```

2. Run `/Users/YOUR_USERNAME/.local/bin/skill-drift-check --check` to compare the
   current evidence with the saved baseline without advancing that baseline or
   deleting a report. If it says no compatible baseline exists, report that
   fact instead of claiming there were no changes. If
   `/Users/YOUR_USERNAME/.local/state/skill-drift/report.md` exists, verify its
   date and reproduce its findings with the same read-only check before
   trusting it. The helper is currently on demand; this skill does not imply
   that cron or a LaunchAgent owns it.
3. Inspect only flagged skill bodies and enough neighboring context to verify
   each finding. The inventory intentionally reports evidence rather than
   deciding architecture:
   - invalid or forbidden frontmatter;
   - descriptions that do not state trigger conditions;
   - bodies over 500 lines;
   - stale explicit `$skill` references;
   - UI default prompts that do not invoke their skill;
   - shebang scripts that are not executable;
   - extraneous skill artifacts.
4. Check cross-skill wiring and instruction placement against current
   `AGENTS.md` and the actual skill catalog. Verify the four-layer boundary:
   - `AGENTS.md` contains only universal behavior and gates needed before a
     conditional skill loads;
   - descriptions contain activation and composition conditions;
   - bodies/references contain conditional workflow and tool-specific detail;
   - scripts/config contain recurring deterministic mechanics.

   Report a placement finding only when behavior is stranded in the wrong
   layer, full global doctrine is unnecessarily duplicated, or moving it would
   materially improve triggering, reliability, or always-loaded context cost.
   Local restatement of a global rule is allowed when it defines a concrete
   skill contract. Do not automatically rewrite findings or enforce obsolete
   taxonomies, missing `arguments`, universal wiring rules, or
   audit-script-pleasing structure.
5. For possible repeated mechanical work, run Scriptify's privacy-safe miner:

   ```bash
   python3 "/Users/YOUR_USERNAME/.codex/skills/tool skills/scriptify/scripts/mine-logs.py" --days 21
   ```

   Frequency is evidence, not proof. Reject patterns already served by a
   deterministic command or requiring per-run judgment.
6. Use targeted memory search only when a specific finding needs provenance.
   Never bulk-load or print raw cross-session user messages.
7. Report material findings first with affected files, impact, evidence, and
   the smallest viable correction. Skip clean skills. Distinguish authored
   skills from vendored or app-managed skills whose structure should not be
   rewritten locally.
8. Apply canonical edits only when already authorized under the global
   `AGENTS.md` approval contract. Use `skill-creator`, validate every changed
   skill with the canonical validator, sync, verify mirrors, capture durable
   decisions, and run `skill-drift-check --refresh` only after the reviewed
   state should become the new hidden baseline.

## Boundaries

- Never write approval queues, checkbox files, or unsolicited deliverables to
  `/Users/YOUR_USERNAME/Files/`.
- Never edit generated mirrors or app-managed `.system` skills.
- Do not mine raw transcript text, classify skills into forced buckets, or add
  resources merely to satisfy heuristics.
- If Ivo wants the drift helper scheduled, use `macos-background-jobs` as a
  separate scheduler decision; this audit does not create live jobs.
