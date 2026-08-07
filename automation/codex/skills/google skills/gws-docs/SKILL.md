---
name: gws-docs
description: >-
  Use when Ivo asks to read, create, append to, inspect, or update Google Docs through
  the gws CLI. Trigger on Google Docs document IDs, doc content edits, document creation,
  or batchUpdate-style changes. Read gws-shared first; use ivo-writer before writing
  prose another human will read.
metadata:
  version: 0.22.5
  openclaw:
    category: "productivity"
    requires:
      bins:
        - gws
    cliHelp: "gws docs --help"
---
# docs (v1)

<core-instructions>

Related skills: read `../gws-shared/SKILL.md` before gws commands. Use `ivo-writer` before drafting or rewriting prose that another human will read inside a Google Doc.


> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, and security rules. If missing, run `gws generate-skills` to create it.

```bash
gws docs {resource} {method} [flags]
```

</core-instructions>

<supporting-info>

## Helper Commands

| Command | Description |
|---------|-------------|
| `+write` | Append text to a document |

</supporting-info>

<supporting-info>

## API Resources

### documents

  - `batchUpdate` — Applies one or more updates to the document. Each request is validated before being applied. If any request is not valid, then the entire request will fail and nothing will be applied. Some requests have replies to give you some information about how they are applied. Other requests do not need to return information; these each return an empty reply. The order of replies matches that of the requests.
  - `create` — Creates a blank document using the title given in the request. Other fields in the request, including any provided content, are ignored. Returns the created document.
  - `get` — Gets the latest version of the specified document.

</supporting-info>

<workflow>

## Discovering Commands

Before calling any API method, inspect it:

```bash
# Browse resources and methods
gws docs --help

# Inspect a method's required params, types, and defaults
gws schema docs.{resource}.{method}
```

Use `gws schema` output to build your `--params` and `--json` flags.

</workflow>
