---
name: project-memory-init
description: >-
  Use when Ivo asks to create, initialize, set up, scaffold, or ensure hidden memory for
  a project folder, or automatically before substantial work in a project folder that
  lacks a nearest .memory/ directory. Trigger on project memory setup, hidden memory,
  .memory initialization, or first substantial project work.
---
# Project Memory Init

<core-instructions>

Use this skill to create hidden per-project memory at `{project}/.memory/`.

Do not create visible `memory/` folders. Do not use MCP servers.

</core-instructions>

<workflow>

## Default

When a project folder is known, run:

```bash
/Users/YOUR_USERNAME/.memory/tools/memory-project-init --project "/path/to/project" --name "Project Name"
```

The initializer creates:

- `.memory/index.md`
- `.memory/current.md`
- `.memory/ledger.ndjson`
- `.memory/raw/chat/`
- `.memory/raw/files/`
- `.memory/raw/links/`
- `.memory/wiki/overview.md`
- `.memory/wiki/preferences.md`
- `.memory/wiki/decisions.md`
- `.memory/wiki/workflows.md`
- `.memory/wiki/sources.md`
- `.memory/audits/`

It also registers the project memory root in `/Users/YOUR_USERNAME/.memory/project-roots.txt` so the daily semantic-index automation can rebuild derived lookup data without manual involvement.

Existing files are left untouched.

</workflow>

<lookup-order>

## Lookup Order

For work inside a project, follow the order in **AGENTS.md §3 (Hidden Auto Memory)** — that is the single source: project `.memory/` first, then global `/Users/YOUR_USERNAME/.memory/` for Ivo-wide preferences; targeted search only (never load whole folders); use `memory-search` for exact lookup and `memory-semantic-query` to locate files by topic.

</lookup-order>

<verification>

## Verify

After initialization:

```bash
MEMORY_ROOT="/path/to/project/.memory" /Users/YOUR_USERNAME/.memory/tools/memory-lint
```

Confirm the project root is registered in `/Users/YOUR_USERNAME/.memory/project-roots.txt` when the initializer reports success. A missing semantic hit is acceptable immediately after initialization; the scheduled `memory-semantic-build` automation (daily 17:00) rebuilds the index when the backend is available. For "which file is about this?" lookup, use `memory-semantic-query` (on PATH).

</verification>
