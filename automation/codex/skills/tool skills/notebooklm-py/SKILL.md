---
name: notebooklm-py
description: >-
  Use when Ivo explicitly says "/notebooklm" or "use NotebookLM", or asks to
  create/manage a NotebookLM notebook, add sources, chat with sources, generate
  podcasts/audio overviews, quizzes, flashcards, study guides, mind maps, video
  explainers, infographics, or download NotebookLM artifacts.
---
# NotebookLM Automation

Use the local `notebooklm` CLI to create and manage notebooks, ingest sources,
ask grounded questions, generate artifacts, and download results. Read only the
reference needed for the current operation:

| Need | Required reference |
|---|---|
| Install, authenticate, refresh cookies, profiles, CI, or diagnose setup | [setup-and-auth.md](references/setup-and-auth.md) |
| Exact commands, JSON envelopes, generation types, exports, or language flags | [command-reference.md](references/command-reference.md) |
| Podcasts, document analysis, bulk import, deep research, long jobs, or output schemas | [automation-workflows.md](references/automation-workflows.md) |
| Errors, exit codes, rate limits, long prompts, limitations, or recovery | [troubleshooting.md](references/troubleshooting.md) |

Read `config/defaults.json` when destination, profile, or notebook-selection
defaults matter. Prefer an explicit notebook id with `-n` in parallel work;
reserve `notebooklm use <id>` for a single-agent session because it mutates
shared context.

## Production preflight

1. Resolve the actual executable with `command -v notebooklm` and inspect
   `notebooklm --version`.
2. Run `notebooklm auth check --test --json`. Do not treat `notebooklm status`
   as an authentication check; it reports selected-notebook context.
3. If the command is missing or auth is unhealthy, read
   [setup-and-auth.md](references/setup-and-auth.md) and repair that path before
   continuing. Existing browser cookies may be used under the global cookie
   policy; keep values secret.
4. Resolve the target notebook exactly. List notebooks when needed and do not
   guess among ambiguous titles or ids.

## Core workflow

1. Create or select the intended notebook.
2. Add the requested URL, file, YouTube, Drive, or research sources. Use `--json`
   when later steps need ids; singular endpoints wrap ids under `.notebook`,
   `.source`, or `.task_id` as documented in the command reference.
3. Confirm source processing before asking questions or generating artifacts.
   Use `source wait` or bounded status checks; do not assume an accepted upload
   is indexed.
4. Ask grounded questions or start the requested generation. Use
   `--prompt-file` for long prompts instead of fragile shell quoting.
5. For long operations, preserve the task id and use the platform's background
   wait path when delegation meets the global threshold. Do not block the main
   conversation with unbounded polling.
6. Download only when requested or when the invoked workflow promises a file.
   Put new standalone user-facing documents in Downloads as HTML by default;
   media and structured data retain their appropriate extensions and requested
   destinations.
7. Verify the final notebook/source/artifact state and the real downloaded file.

## Autonomy Rules

**Run automatically (no confirmation):**
- `notebooklm status` - check context
- `notebooklm auth check` - diagnose auth issues
- `notebooklm auth inspect` - list Google accounts visible to a browser (read-only)
- `notebooklm auth refresh` - server-side SIDTS refresh of the active profile (no new profile, no destructive writes)
- `notebooklm auth refresh --browser-cookies <browser>` - re-extract cookies from a browser into the active profile (rebuilds `storage_state.json` for the same `--profile`, not a new one)
- `notebooklm list` - list notebooks
- `notebooklm source list` - list sources
- `notebooklm artifact list` - list artifacts
- `notebooklm language list` - list supported languages
- `notebooklm language get` - get current language
- `notebooklm language set` - set language (global setting)
- `notebooklm artifact wait` - wait for artifact completion (in subagent context)
- `notebooklm source wait` - wait for source processing (in subagent context)
- `notebooklm research status` - check research status
- `notebooklm research wait` - wait for research (in subagent context)
- `notebooklm use <id>` - set context (⚠️ SINGLE-AGENT ONLY - use `-n` flag in parallel workflows)
- `notebooklm create` - create notebook
- `notebooklm ask "..."` - chat queries (without `--save-as-note`)
- `notebooklm history` - display conversation history (read-only)
- `notebooklm source add` - add sources
- `notebooklm profile list` - list profiles
- `notebooklm profile create` - create profile
- `notebooklm profile switch` - switch active profile
- `notebooklm doctor` - check environment health

**Ask before running:**
- `notebooklm delete` / `source delete` / `note delete` / `share remove` / `profile delete` - destructive. Once approved, pass `--yes`/`-y` to skip the confirmation prompt (uniform across every destructive command). On the commands that also expose `--json` (e.g. `delete`, `source delete`, `note delete`, `share remove`), `--json` implies `--yes` so non-interactive callers never hang on the prompt; `profile delete` has no `--json`, so pass `--yes` explicitly there.
- `notebooklm generate *` - long-running, may fail
- `notebooklm download *` - writes to filesystem
- `notebooklm artifact wait` - long-running (when in main conversation)
- `notebooklm source wait` - long-running (when in main conversation)
- `notebooklm research wait` - long-running (when in main conversation)
- `notebooklm ask "..." --save-as-note` - writes a note
- `notebooklm history --save` - writes a note

## Failure and privacy contract

- Never print or persist raw browser cookies, session values, or account tokens.
- Treat rate limits, processing delays, and provider generation failures as
  different states. Preserve ids and pending work across a retry.
- Attempt bounded diagnosis and the documented recovery path. If the path
  remains unavailable or a fallback changes behavior, coverage, freshness, or
  output, report the exact failure and repair action under the global failure
  contract.
- Do not delete notebooks, sources, notes, profiles, artifacts, or sharing
  permissions without the explicit authority described above.
- Do not share externally merely because an artifact was generated or
  downloaded.

## Verification

Use `--json` for machine checks, then confirm the final state with the matching
list/status command. Verify downloaded artifacts exist, are non-empty, and use
the promised format. For operation-specific commands and expected JSON fields,
read the command reference; for rate-limit and exit-code interpretation, read
the troubleshooting reference.
