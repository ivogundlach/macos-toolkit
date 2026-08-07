---
name: local-read-connectors
description: Use when Ivo asks to read, find, summarize, inspect, audit, or answer from the custom local read connector script for Safari history, Screen Time usage, Apple Mail/email, Apple Notes, Apple Reminders, Apple Calendar, or public YouTube metadata.
---

# Local Read Connectors

<core-instructions>

Use the local read helper before asking Ivo to paste, export, screenshot, or manually locate information. These commands are read-only by design.

Machine-readable helper paths live in `config/defaults.json`; use those values when scripting or checking for path drift.

Primary helper:

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read
```

Underlying script:

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/read_connectors.py
```

</core-instructions>

<safety-boundaries>

## Rules

1. Use connector-first behavior for Ivo's daily-app data.
2. Prefer narrow searches: small `--days`, small `--limit`, specific query terms.
3. Start with metadata where possible, then inspect more only if needed.
4. Do not print large private bodies or full histories unless Ivo explicitly asks.
5. Ask Ivo to paste content only after the relevant connector is unavailable or targeted searches fail.
6. For Google Workspace data, use `gws` and the installed `gws-*` skills instead of this local helper.
7. For email requests, search Gmail with `gws` first when authenticated, then search Apple Mail metadata with this helper before asking Ivo to paste.
8. Use an AskUserQuestion-style source-selection prompt only when several plausible local records match. If the current agent surface supports a native ask-user popup, use it; otherwise ask one plain-English question using sender, title/subject, date, and app/mailbox labels rather than raw ids.

</safety-boundaries>

<supporting-info>

## Sources And Commands

### Safari History

Use when Ivo asks about websites visited, browsing patterns, recently viewed pages/domains, or "what site was I using?"

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read safari-history --days 7 --limit 20
```

Output: domains, visit counts, latest visit timestamp.

### Screen Time / App Web Usage

Use when Ivo asks what he spent time on, website usage, app/web attention, or daily/weekly usage patterns.

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read screen-time-domains --days 7 --limit 20
```

Output: domains, event counts, approximate active hours.

### Apple Calendar

Use when Ivo asks about calendar events, upcoming schedule, dates, appointments, or deadlines in Apple Calendar.

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read calendar-upcoming --days 14 --limit 25
```

Output: event title, start/end, calendar name, URL if present.

### Apple Reminders

Use when Ivo asks about todos, reminders, open tasks, due reminders, or what he needs to do. Apple Reminders is a priority source for Ivo.

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read reminders-open --limit 50
```

Output: reminder title, list, due/display dates, priority, whether notes exist.

### Apple Mail Summary

Use to confirm Apple Mail indexing and account/mailbox totals before deeper mail work.

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read mail-summary
```

Output: mailbox count, total messages, unread messages, deleted messages.

### Apple Mail Search

Use when Ivo mentions an email, sender, subject, organization, or mail clue and Gmail does not find it or the account may be in Apple Mail.

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read mail-search "uah housing" --days 90 --limit 10
```

Output: message row id, sender, sender name, subject, received timestamp, mailbox, read/flagged state.

For email body handling, use Gmail body reads when a Gmail message ID is available:

```bash
gws gmail users messages list --params '{"userId":"me","maxResults":10,"q":"newer_than:30d housing"}'
gws gmail +read --id MESSAGE_ID --headers --format json
```

When Apple Mail metadata search finds one high-confidence message and the body is needed, use the local body helper instead of asking Ivo to paste the email:

```bash
/Users/YOUR_USERNAME/.local/bin/apple-mail-rowid-body ROW_ID
```

If several plausible messages match, ask Ivo to choose by sender, subject, date, and mailbox before reading deeper. Do not expose raw row ids unless needed for disambiguation.

### Apple Notes

Use when Ivo asks to search, inspect, or summarize Apple Notes.

Stats:

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read notes
```

Search:

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read notes "query terms"
```

Output: from `apple-notes-parser`; avoid dumping full note bodies unless Ivo asks for the content.

### YouTube Public Metadata

Use when Ivo asks about a public YouTube URL, video metadata, channel, duration, views, upload date, or description.

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read youtube "https://www.youtube.com/watch?v=VIDEO_ID"
```

Output: id, title, channel, channel URL, duration, view count, upload date, webpage URL, description.

</supporting-info>

<fallbacks>

## Fallbacks

- If a local database is locked or inaccessible, report the exact source that failed and try the next relevant connector.
- If a query returns no rows, broaden terms once before asking Ivo for more detail.
- For signed-in websites with no CLI/API/local database, use Chrome only when needed and scoped.

</fallbacks>
