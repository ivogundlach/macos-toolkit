---
name: gws-drive
description: >-
  Use when Ivo asks to find, list, upload, download, copy, move, share, permission,
  inspect, or manage Google Drive files, folders, and shared drives. Trigger on Drive
  URLs, file IDs, folder organization, permissions, comments, revisions, file search, or
  shared-drive work. Read gws-shared first.
metadata:
  version: 0.22.5
  openclaw:
    category: "productivity"
    requires:
      bins:
        - gws
    cliHelp: "gws drive --help"
---
# drive (v3)

<core-instructions>

> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, and security rules. If missing, run `gws generate-skills` to create it.

```bash
gws drive {resource} {method} [flags]
```

</core-instructions>

<supporting-info>

## Helper Commands

| Command | Description |
|---------|-------------|
| `+upload` | Upload a file with automatic metadata |

</supporting-info>

<supporting-info>

## API Resources

Resource → methods. Run `gws schema drive.{resource}.{method}` for params/types and `gws drive --help` to browse. (`fields` is required on `about.get`, `comments.*`, and other read methods — see `gws schema`.)

- **about**: get
- **accessproposals**: get, list, resolve *(only approvers can list; else 403)*
- **approvals**: get, list
- **apps**: get, list
- **changes**: getStartPageToken, list, watch
- **channels**: stop
- **comments**: create, delete, get, list, update
- **drives** (shared drives): create, get, hide, list, unhide, update *(list accepts `q`)*
- **files**: copy, create, download, export, generateIds, get, list, listLabels, modifyLabels, update, watch *(list returns trashed too — add `trashed=false`; export ≤10 MB; download URLs valid 24h)*
- **operations**: get
- **permissions**: create, delete, get, list, update *(concurrent perm ops unsupported — last write wins)*
- **replies**: create, delete, get, list, update
- **revisions**: delete, get, list, update *(list may omit old revisions for heavily-edited Docs/Sheets/Slides)*
- **teamdrives**: create, get, list, update *(all deprecated — use `drives.*`)*

</supporting-info>

<workflow>

## Discovering Commands

Before calling any API method, inspect it:

```bash
# Browse resources and methods
gws drive --help

# Inspect a method's required params, types, and defaults
gws schema drive.{resource}.{method}
```

Use `gws schema` output to build your `--params` and `--json` flags.

</workflow>
