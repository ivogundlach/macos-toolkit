---
name: memory-audit
description: Use when Ivo asks to audit, check, clean, prune, repair, verify, or improve the hidden memory system, or after memory edits need deterministic validation.
---

# Memory Audit

<core-instructions>

Audit the relevant hidden memory root.

- For global user-wide memory: `/Users/YOUR_USERNAME/.memory/`
- For project-specific memory: the project's `.memory/`

Default to read-only when Ivo asks for an audit. If Ivo asks to fix, make the smallest targeted edits and run lint again.

</core-instructions>

<workflow>

## Required Check

Always run:

```bash
MEMORY_ROOT="/path/to/relevant/.memory" /Users/YOUR_USERNAME/.memory/tools/memory-lint
```

Also check derived semantic lookup health when useful:

```bash
MEMORY_ROOT="/path/to/relevant/.memory" memory-semantic-query "memory audit smoke test" --top 3
```

If the semantic index is absent, stale, or unhelpful, report that as an automation/indexing status, not as memory corruption. The rebuild wrapper is `/Users/YOUR_USERNAME/.memory/tools/memory-semantic-build`.

**Semantic-index usage trap (recurred 3-4×):** near-zero agy/Antigravity usage on scheduled runs is EXPECTED — the hash cache means only changed files hit agy. Verify health from run logs and output artifacts (`~/.memory/semantic-index-status.json`, `~/.memory/semantic-index.sqlite` freshness, logs under `~/.memory/logs/`), never from provider usage meters, and do not "fix" a healthy pipeline. The inverse also holds: a sudden 5h-limit drain usually means a large new file batch entered an indexed root, not a bug.

For a project memory audit, set `MEMORY_ROOT`:

```bash
MEMORY_ROOT="/path/to/project/.memory" /Users/YOUR_USERNAME/.memory/tools/memory-lint
```

Then inspect only relevant files:

- `index.md`
- `current.md`
- `ledger.ndjson`
- targeted files in `wiki/`

Use search, not broad loading:

```bash
/Users/YOUR_USERNAME/.memory/tools/memory-search 'query'
```

Verify any audit finding against canonical files before reporting it.

</workflow>

<review-criteria>

## Review Criteria

Prioritize these issues:

1. Invalid `ledger.ndjson` JSON.
2. Wiki references to missing `mem_...` ids.
3. Ledger entries whose target wiki file does not exist.
4. Durable wiki claims with no ledger id.
5. Contradictory claims not marked `conflicted` or superseded.
6. Stale `current.md` entries.
7. Wiki pages over 300 lines or broad pages that should be split.
8. Raw capture missing for a durable claim.
9. Semantic-index automation not loaded, registered, or able to rebuild when expected.

</review-criteria>

<output-contract>

## Output

For an audit, report:

- findings first, ordered by severity
- exact file paths
- whether the issue is deterministic or judgment-based
- the smallest fix

If there are no issues, say so and note any residual judgment risk.

</output-contract>

<safety-boundaries>

## Rules

- Do not use MCP servers.
- Do not rewrite memory wholesale.
- Do not delete raw files unless Ivo explicitly asks.
- Prefer marking stale/conflicted/superseded over erasing history.

</safety-boundaries>
