---
name: handoff
description: >-
  Use only when Ivo explicitly asks to preserve or transfer unfinished work to
  another Codex task, agent, or product, or explicitly requests a durable
  milestone handoff. Trigger on phrases such as "handoff", "move this to
  another task", "continue this with another agent", or "close this task but
  preserve the remaining work". Do not use for automatic compaction or normal
  continuation in the same task.
metadata:
  argument-hint: What work and destination should the handoff cover?
---

# Handoff

Create a cold-start continuation document only when work crosses a task or
agent boundary. Same-task compaction and later continuation need no handoff.

## Required content

1. **Context** — the objective and present situation.
2. **What exists now** — completed artifacts, decisions, and explicitly
   rejected ideas that must not be reintroduced.
3. **Verified vs unverified** — exact checks already run and remaining gaps.
4. **Open work** — numbered next actions with absolute paths and first commands.
5. **Load-bearing preferences** — only standing Ivo rules needed for this work.
6. **Suggested skills** — what the receiving agent should invoke and why.

Reference existing plans, commits, reports, memory records, or other durable
artifacts instead of copying them. The receiving agent starts cold, so every
reference must be resolvable without this conversation.

## Ingest

1. Select the memory root: the relevant project `.memory/` for project work;
   otherwise `/Users/YOUR_USERNAME/.memory/`. Initialize missing project memory.
2. Compose the Markdown in memory or scratch. Do not create a loose visible
   handoff file.
3. Pipe it to `/Users/YOUR_USERNAME/.memory/tools/memory-capture` with
   `MEMORY_ROOT`, `--topic "handoff: {topic}"`, `--type note`, a concise
   `--claim`, `--target wiki/handoffs.md`, and
   `--source-kind local_file --status verified --confidence 1.0`.
4. Add one concise `wiki/handoffs.md` bullet containing the full returned
   `mem_...` id, memory-root-relative raw path, scope, destination, and next
   action. Create/index that wiki page if needed. Update `current.md` only for
   unfinished work that remains active.
5. Run `memory-lint` with the selected `MEMORY_ROOT`.
6. If Ivo requested another export path, write it only after memory ingestion
   succeeds unless he explicitly opted out of memory ingestion.
7. Return the ledger id and a verified absolute clickable raw-file link.

Never include passwords, API keys, raw cookies, authentication tokens, or
unrelated private details. Keep necessary task identifiers in hidden memory.
If capture succeeds but citation, lint, or export fails, report the partial
state and exact repair action; do not repeat the capture blindly. Do not rebuild
derived semantic indexes manually.
