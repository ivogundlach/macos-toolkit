# Public toolkit notes

This candidate is a corpus-free source export. The hidden memory corpus,
personal text, indexes, embeddings, backups, history, cookies, and runtime
state are absent. The included memory-tool source documents interfaces and
sanitized examples only; it does not contain Ivo's memories.

## Stack catalog and settings

`STACK.json` is the entry point for agents. It records installed applications,
package names, local commands, safe macOS facts, provenance, and a closed
coverage matrix. It does not infer an application's purpose when the machine
does not provide evidence; unknown annotations remain null.

`STACK_POLICY.json` is the exact public-settings contract. Each approved key has
a required value type and, for strings and numbers, an allowed set or range.
`settings/MANIFEST.json` reports exported and still-pending key counts by domain.
Preference files are parsed locally but never copied wholesale. A new or changed
value outside its approved shape stops the export instead of being redacted
opportunistically.

## Memory layout

Install the included source into a location you control, for example
`/Users/YOUR_USERNAME/.local/share/memory-tools`. Keep your corpus in a
separate private directory such as `/Users/YOUR_USERNAME/.memory`; do not add
that directory to this repository.

The source contains the initializer, index, query, backup, restore, and health
entry points. Read each script's `--help` output and inspect its paths before
running it. A generic review sequence is:

```text
memory-init --root /Users/YOUR_USERNAME/.memory
memory-index --root /Users/YOUR_USERNAME/.memory --check
memory-query --root /Users/YOUR_USERNAME/.memory --text "example topic"
memory-backup --root /Users/YOUR_USERNAME/.memory --destination /secure/backup
memory-restore --root /Users/YOUR_USERNAME/.memory --source /secure/backup
memory-health --root /Users/YOUR_USERNAME/.memory
```

These examples use placeholder paths and text; they are not Ivo's commands or
personal corpus. Adapt executable names to the source files present in this
candidate and verify permissions, retention, and backup encryption yourself.

## Restoration boundary

The exporter adapts the exact private home prefix to
`/Users/YOUR_USERNAME` in source files. It does not install LaunchAgents,
create accounts, provision credentials, or execute a component. Restore one
component at a time, inspect any network or filesystem access, and record the
verification result locally.

The complete phishing-header skill and `references/api-reference.md` are
included. Three exact placeholder authorization-header lines receive a
component-specific `gitleaks:allow` annotation; no global scanner suppression
is used. `automation/smart-wake/lib.sh`, the Smart Wake LaunchAgent, the Tool
Status Dashboard scanner, and MacroSimulator's AgyChat source are included
with only declared home-prefix/runtime/preview adapters.

The synthetic-secret `automation/memory-tests/test_redaction.py` fixture and
private-only `automation/local-bin/personal-repo-sync` remain excluded. The
requested `apps/NutrientTracker/tools/GeneratedData.swift` path is absent from
the immutable target snapshot, so it is documented as absent rather than
recreated. `COMPONENTS.md` lists every policy exclusion and its reason without
copying source excerpts or secret values.
