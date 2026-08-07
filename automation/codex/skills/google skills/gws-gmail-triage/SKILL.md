---
name: gws-gmail-triage
description: >-
  Use when Ivo asks for an unread Gmail inbox summary, recent Gmail overview,
  sender/subject/date scan, or filtered mailbox triage. Trigger on phrases like "triage
  Gmail", "show unread email", "what is in my inbox", or Gmail search summaries. Read
  gws-shared first; use gws-gmail-read when a message body is needed.
metadata:
  version: 0.22.5
  openclaw:
    category: "productivity"
    requires:
      bins:
        - gws
    cliHelp: "gws gmail +triage --help"
---
# gmail +triage

<core-instructions>

Related skills: read `../gws-shared/SKILL.md` before gws commands. Use `gws-gmail-read` when triage identifies a Gmail message whose body or headers are needed.


> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, and security rules. If missing, run `gws generate-skills` to create it.

Show unread inbox summary (sender, subject, date)

</core-instructions>

<supporting-info>

## Usage

```bash
gws gmail +triage
```

## Flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--max` | — | 20 | Maximum messages to show (default: 20) |
| `--query` | — | — | Gmail search query (default: is:unread) |
| `--labels` | — | — | Include label names in output |

## Examples

```bash
gws gmail +triage
gws gmail +triage --max 5 --query 'from:boss'
gws gmail +triage --format json | jq '.[].subject'
gws gmail +triage --labels
```

</supporting-info>

<safety-boundaries>

## Tips

- Read-only — never modifies your mailbox.
- Defaults to table output format.

</safety-boundaries>

<supporting-info>

## See Also

- [gws-shared](../gws-shared/SKILL.md) — Global flags and auth
- [gws-gmail](../gws-gmail/SKILL.md) — All send, read, and manage email commands

</supporting-info>
