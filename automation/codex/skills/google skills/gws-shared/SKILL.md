---
name: gws-shared
description: >-
  Use whenever any gws-* Google Workspace skill is active and needs authentication,
  global flags, output formats, dry-run behavior, pagination, sanitization, shell
  quoting, or security rules for the gws CLI. Trigger before calling gws calendar, docs,
  drive, gmail, people, sheets, or tasks commands.
metadata:
  version: 0.22.5
  openclaw:
    category: "productivity"
    requires:
      bins:
        - gws
---
# gws — Shared Reference

<supporting-info>

## Installation

The `gws` binary must be on `$PATH`. See the project README for install options.

</supporting-info>

<auth>

## Authentication

```bash
# Browser-based OAuth (interactive)
gws auth login

# Service Account
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

</auth>

<supporting-info>

## Global Flags

| Flag | Description |
|------|-------------|
| `--format <FORMAT>` | Output format: `json` (default), `table`, `yaml`, `csv` |
| `--dry-run` | Validate locally without calling the API |
| `--sanitize <TEMPLATE>` | Screen responses through Model Armor |

## CLI Syntax

```bash
gws {service} {resource} [sub-resource] {method} [flags]
```

### Method Flags

| Flag | Description |
|------|-------------|
| `--params '{"key": "val"}'` | URL/query parameters |
| `--json '{"key": "val"}'` | Request body |
| `-o, --output <PATH>` | Save binary responses to file |
| `--upload <PATH>` | Upload file content (multipart) |
| `--page-all` | Auto-paginate (NDJSON output) |
| `--page-limit <N>` | Max pages when using --page-all (default: 10) |
| `--page-delay <MS>` | Delay between pages in ms (default: 100) |

</supporting-info>

<safety-boundaries>

## Security Rules

- **Never** output secrets (API keys, tokens) directly
- **Always** confirm with user before executing write/delete commands
- Prefer `--dry-run` for destructive operations
- Use `--sanitize` for PII/content safety screening

</safety-boundaries>

<supporting-info>

## Shell Tips

- **zsh `!` expansion:** Sheet ranges like `Sheet1!A1` contain `!` which zsh interprets as history expansion. Use double quotes with escaped inner quotes instead of single quotes:
  ```bash
  # WRONG (zsh will mangle the !)
  gws sheets +read --spreadsheet ID --range 'Sheet1!A1:D10'

  # CORRECT
  gws sheets +read --spreadsheet ID --range "Sheet1!A1:D10"
  ```
- **JSON with double quotes:** Wrap `--params` and `--json` values in single quotes so the shell does not interpret the inner double quotes:
  ```bash
  gws drive files list --params '{"pageSize": 5}'
  ```

</supporting-info>

