---
name: gws-gmail
description: >-
  Use when Ivo asks to search, read, draft, send, reply, forward, label, watch, or manage
  Gmail through the gws CLI. Trigger on Gmail message IDs, threads, labels, drafts,
  sending, replying, forwarding, or mailbox management. Read gws-shared first; use
  ivo-writer for any email text another human will read.
metadata:
  version: 0.22.5
  openclaw:
    category: "productivity"
    requires:
      bins:
        - gws
    cliHelp: "gws gmail --help"
---
# gmail (v1)

<core-instructions>

Related skills: read `../gws-shared/SKILL.md` before gws commands. Use `ivo-writer` before composing, replying, forwarding, or polishing email text another human will read.


> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, and security rules. If missing, run `gws generate-skills` to create it.

```bash
gws gmail {resource} {method} [flags]
```

</core-instructions>

<supporting-info>

## Helper Commands

| Command | Description |
|---------|-------------|
| `+send` | Send an email |
| `+triage` | Show unread inbox summary (sender, subject, date) |
| `+reply` | Reply to a message (handles threading automatically) |
| `+reply-all` | Reply-all to a message (handles threading automatically) |
| `+forward` | Forward a message to new recipients |
| `+read` | Read a message and extract its body or headers |
| `+watch` | Watch for new emails and stream them as NDJSON |

</supporting-info>

<supporting-info>

## API Resources

### users

  - `getProfile` — Gets the current user's Gmail profile.
  - `stop` — Stop receiving push notifications for the given user mailbox.
  - `watch` — Set up or update a push notification watch on the given user mailbox.
  - `drafts` — Operations on the 'drafts' resource
  - `history` — Operations on the 'history' resource
  - `labels` — Operations on the 'labels' resource
  - `messages` — Operations on the 'messages' resource
  - `settings` — Operations on the 'settings' resource
  - `threads` — Operations on the 'threads' resource

</supporting-info>

<workflow>

## Discovering Commands

Before calling any API method, inspect it:

```bash
# Browse resources and methods
gws gmail --help

# Inspect a method's required params, types, and defaults
gws schema gmail.{resource}.{method}
```

Use `gws schema` output to build your `--params` and `--json` flags.

</workflow>
