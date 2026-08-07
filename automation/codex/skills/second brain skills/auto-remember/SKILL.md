---
name: auto-remember
description: >-
  Use whenever the conversation produces anything plausibly durable — Ivo states a
  preference, identity fact, decision, workflow, project context, standing instruction,
  or source reference; Ivo corrects the agent or repeats a request; the agent discovers a
  non-obvious environment, tool, account, or setup fact during work; or onboarding-style
  questions get answered. Capture liberally: if unsure whether something is durable,
  capture it. Skip only for secrets, pure task chatter, and things Ivo says not to
  remember. When a newly observed agent-caused correction is reusable and has an
  identifiable owning rule, skill, or reference, hand the captured record to
  `improve-system` once; do not wait for Ivo to say improve-system.
---

# Auto Remember

<core-instructions>

Use hidden memory roots:

- Global Ivo-wide memory: `/Users/YOUR_USERNAME/.memory/`
- Project-specific memory: nearest project `.memory/`

This skill is automatic. Do not ask whether to remember ordinary durable facts. Capture them, update the smallest useful wiki surface, lint, and continue the user task.

</core-instructions>

<workflow>

## Destination

Choose the memory destination before writing:

| Information type | Destination |
|---|---|
| Ivo-wide preferences, identity, communication style, standing tool rules | `/Users/YOUR_USERNAME/.memory/` |
| Facts, decisions, workflows, sources, or constraints for a specific project | that project's `.memory/` |
| A project-specific fact when the project has no `.memory/` yet | initialize it with `project-memory-init`, then write there |
| Ambiguous fact that affects both | write the durable project detail to project `.memory/`; write only the reusable preference/rule globally |

When working inside a project, use the nearest ancestor `.memory/` as `MEMORY_ROOT`. Use global memory only for Ivo-wide facts.

</workflow>

<capture-criteria>

## Capture

Capture liberally. The bar is "plausibly useful in a future session", not "certainly durable". When in doubt, capture — a stale entry costs one memory-audit line; a missed entry costs a repeated conversation.

Always capture:

- user preferences and standing instructions
- identity, role, voice, and working style
- project facts, active constraints, decisions, and rationale
- workflows, repeatable processes, and source references
- answers to onboarding-style questions
- corrections Ivo makes to agent behavior or output (even small ones)
- requests Ivo has now made more than once
- non-obvious environment, tool, account, path, or setup facts the agent discovered while working (label as inference or file-derived per Source Status)
- rejected options and the reason, when a choice was made

Do not capture:

- secrets, credentials, tokens, session IDs, raw private keys, or passwords
- one-off task chatter, transient command output, or temporary status
- guesses as facts
- long copyrighted source text beyond short excerpts needed for provenance
- anything Ivo explicitly says not to remember

</capture-criteria>

<system-reinforcement>

`auto-remember` is the single detector and orchestrator for newly observed corrections. When all of
these criteria hold—an observed agent-caused failure or correction, plausible recurrence, an
identifiable owning rule/skill/reference, and a durable corrective instruction—capture the memory
evidence and hand the already-captured record to `improve-system` once; memory-only is incomplete.
Use existing evidence and logs, and never reenact a harmful UI, data, or external failure. For a
one-off or transient issue, or when no owner is identifiable, capture memory only.

Mark the correction as `escalated` in turn state after the handoff. If it is already captured or
escalated, reuse the existing raw/ledger record and do not capture or invoke again.

</system-reinforcement>

<workflow>

## Workflow

1. Select the correct `MEMORY_ROOT` using the Destination table.
2. Read `$MEMORY_ROOT/index.md` and `$MEMORY_ROOT/current.md` only when needed.
3. Use automatic memory lookup when existing context may affect the task: `memory-search` for exact strings, `memory-semantic-query` to find which file covers the topic.
4. Extract atomic durable claims. Capture as many as the turn genuinely yields — do not ration; several small atomic claims beat one merged blob.
5. Save exact relevant user input to `raw/chat/` with the local CLI.
6. Append one ledger record per durable claim.
7. Update only the relevant `wiki/` page.
8. Update `current.md` only for active constraints, current projects, or immediately useful state.
9. Run `MEMORY_ROOT="$MEMORY_ROOT" /Users/YOUR_USERNAME/.memory/tools/memory-lint`.
10. Do not manually rebuild the semantic index after capture; the daily background job owns refreshes.

</workflow>

<output-contract>

## Visibility

Captures are silent storage but never invisible events. After capturing, tell Ivo in chat — one compact line per capture, at the end of the response:

```
Remembered: <claim in a few words> (<type>, <root>)
```

Example: `Remembered: prefers HTML for saved reports (preference, global)`. For 3+ captures in one turn, one summary line is enough: `Remembered 4 facts: <comma-separated stubs>`. Never skip the line — Ivo calibrates trust in auto-memory by seeing it fire. Do not print full ledger ids or paths unless Ivo asks.

</output-contract>

<supporting-info>

## Commands

For one claim:

```bash
ROOT="/path/to/selected/.memory"
printf '%s\n' 'EXACT USER EXCERPT' | MEMORY_ROOT="$ROOT" /Users/YOUR_USERNAME/.memory/tools/memory-capture \
  --topic 'short topic' \
  --type preference \
  --claim 'Atomic durable claim.' \
  --target wiki/preferences.md
```

For multiple claims from the same raw excerpt:

```bash
ROOT="/path/to/selected/.memory"
printf '%s\n' 'EXACT USER EXCERPT' | MEMORY_ROOT="$ROOT" /Users/YOUR_USERNAME/.memory/tools/memory-capture \
  --topic 'short topic' \
  --type decision \
  --claim 'First durable claim.' \
  --target wiki/decisions.md

MEMORY_ROOT="$ROOT" /Users/YOUR_USERNAME/.memory/tools/memory-capture \
  --raw-file raw/chat/YYYYMMDD-HHMMSS-short-topic.md \
  --type workflow \
  --claim 'Second durable claim.' \
  --target wiki/workflows.md
```

Use the returned `ledger_id` in the wiki text as `mem_...`.

</supporting-info>

<source-rules>

## Source Status

- User statement: `status=verified`, `confidence=1.0`.
- Local file: cite the path in the claim or source.
- External source: include URL and access date in the claim/source.
- Agent inference: `status=inference`, confidence below `0.8`, and label the wiki text as inference.

</source-rules>

<context-control>

## Context Control

Never load all of `.memory/`. For targeted lookup and the search-mode routing (`memory-search` = exact string; `memory-semantic-query` = which file is *about* a topic; both on PATH), follow **AGENTS.md §3 (Hidden Auto Memory)** — that is the single source for these rules. Local CLI helpers only, run with `MEMORY_ROOT` set to the selected `.memory/`; never an MCP server. Treat semantic-query output as pointers over canonical `wiki/`/`ledger.ndjson`, not source of truth — open the file before relying on it.

</context-control>
