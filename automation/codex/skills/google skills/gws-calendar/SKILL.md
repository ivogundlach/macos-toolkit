---
name: gws-calendar
description: >-
  Use when Ivo asks to create, edit, delete, search, inspect, or manage Google Calendar
  calendars or events. Trigger on Google Calendar scheduling tasks, event CRUD, calendar
  ACLs, free/busy checks, reminders, calendar metadata, or event IDs. Read gws-shared
  first; use gws-calendar-agenda for simple upcoming-agenda requests.
metadata:
  version: 0.22.5
  openclaw:
    category: "productivity"
    requires:
      bins:
        - gws
    cliHelp: "gws calendar --help"
---
# calendar (v3)

<core-instructions>

> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, and security rules. If missing, run `gws generate-skills` to create it.

```bash
gws calendar {resource} {method} [flags]
```

</core-instructions>

<supporting-info>

## Helper Commands

| Command | Description |
|---------|-------------|
| `+insert` | create a new event |
| `+agenda` | Show upcoming events across all calendars |

</supporting-info>

<supporting-info>

## API Resources

Resource → methods. Run `gws schema calendar.{resource}.{method}` for params and `gws calendar --help` to browse.

- **acl**: delete, get, insert, list, patch, update, watch
- **calendarList**: delete, get, insert, list, patch, update, watch
- **calendars**: clear, delete, get, insert, patch, update
  - `clear` deletes **all** events on the **primary** calendar; `delete` removes a **secondary** calendar. `insert` makes the authenticated user the data owner — authenticate as the intended owner, not a service account.
- **channels**: stop
- **colors**: get
- **events**: delete, get, import, insert, instances, list, move, patch, quickAdd, update, watch
  - `get` by iCalendar ID: use `list` with `iCalUID`. `move` works on **default** events only (not birthday/focusTime/fromGmail/outOfOffice/workingLocation). `quickAdd` creates from a text string.
- **freebusy**: query
- **settings**: get, list, watch

</supporting-info>

<workflow>

## Discovering Commands

Before calling any API method, inspect it:

```bash
# Browse resources and methods
gws calendar --help

# Inspect a method's required params, types, and defaults
gws schema calendar.{resource}.{method}
```

Use `gws schema` output to build your `--params` and `--json` flags.

</workflow>
