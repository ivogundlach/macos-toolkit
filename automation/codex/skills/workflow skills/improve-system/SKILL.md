---
name: improve-system
description: >-
  Use when Ivo says improve-system or asks to fold lessons from the current
  session back into the agent system: capture a correction, fix a skill that
  misfired or failed to trigger, refine a standing rule, or turn repeated
  mechanical work into a script. Review only the current in-context session
  and route each durable improvement to hidden memory, AGENTS.md, an existing
  skill, skill-audit, memory-audit, or scriptify. Skip one-off memory captures
  handled by auto-remember and corpus-wide audits handled by skill-audit. Also
  trigger proactively on an `auto-remember` handoff or an explicit user
  correction, and consume the already-captured record without recapturing it.
---

# Improve System

Turn evidence from the current session into durable system improvements. Do
not bulk-load old transcripts or recreate history that `auto-remember` should
already have captured.

## Auto-remember handoff

Accept an `auto-remember` handoff as the evidence record; do not call
`auto-remember` again or duplicate a captured/escalated correction. Route one
smallest durable gotcha to its owning rule, skill, or reference. Prepare the
exact patch automatically, but apply it only when the current request already
authorizes that concrete system edit; otherwise request approval once.

## Procedure

1. Verify each reported problem against the current conversation or the
   smallest relevant artifact before treating it as a durable finding. Inspect
   targeted memory only when prior context affects the finding. If Ivo invoked
   this skill because of a current
   `~/.local/state/skill-drift/report.md`, verify its date and source before
   using it; the report's mere presence does not make it current.
2. Extract one concern per finding:
   - a skill fired incorrectly or failed to fire;
   - Ivo corrected behavior or required repeated iteration;
   - a durable preference, decision, workflow fact, or environment fact is not
     captured;
   - an `AGENTS.md` rule is missing, ambiguous, stale, or contradictory;
   - a deterministic action is being reconstructed with model work;
   - a memory or skill artifact has a concrete integrity problem.
3. Route each supported finding to the smallest responsible layer. Apply this
   placement test before choosing the target:
   - behavior or authorization needed before any conditional skill loads, or
     across unrelated task types → canonical `AGENTS.md`;
   - activation conditions and neighboring-skill composition → the skill's
     frontmatter description;
   - conditional workflow, tool ladder, platform detail, schema, or local
     failure handling → the owning skill body or reference;
   - recurring deterministic mechanics or machine-readable policy → an
     existing script/config, or `scriptify` when none exists.

   Local reinforcement is justified only when a skill translates a global rule
   into its concrete contract; point to the global rule instead of repeating its
   full prose. When Ivo names a skill as the thing that misbehaved, treat it as
   the repair subject rather than invoking it merely because its name appears in
   the complaint. Route durable facts to `auto-remember`, memory integrity to
   `memory-audit`, one-skill changes to `skill-creator`, and corpus-wide drift to
   `skill-audit`. Keep personal skills in clear category folders under the
   canonical skill root when creating or relocating them; flattened mirror
   layouts are generated outputs, not the canonical organization.
4. Apply automatic memory capture and read-only validation when in scope.
   Apply skill or `AGENTS.md` changes only when Ivo has already approved the
   concrete change; otherwise request approval under the global `AGENTS.md`
   contract. Ask one concise question only when evidence cannot determine the
   correct layer or behavior.
5. After an approved canonical system change:
   - validate the changed artifact;
   - append one concise applied-change record per distinct routed change with
     `/Users/YOUR_USERNAME/.local/bin/improve-system-log add "<change>"`;
   - run `/Users/YOUR_USERNAME/.local/bin/codex-to-claude-sync` and
     `/Users/YOUR_USERNAME/.local/bin/codex-sync-verify`;
   - run `memory-lint` when memory changed.

## Boundaries

- Treat the existing files under
  `/Users/YOUR_USERNAME/.local/state/improve-system/` as preserved history, not a
  queue that must be cleared before new work.
- Do not create approval files, Markdown checkboxes, new storage roots, hooks,
  or scheduled model runs.
- Do not edit generated Claude, Gemini, or Antigravity mirrors directly.
- Do not infer a system change from a transient failure, unsupported hunch, or
  preference that already has a clear canonical source.
