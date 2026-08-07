---
name: twitter-ingest
description: >-
  Use when Ivo asks to ingest, add, save, or archive a Twitter/X post, tweet, or
  thread — "ingest this Twitter post", "add this tweet to my archive", "save this X
  thread". Adds a source-card to the EXISTING Twitter Bookmarks Archive HTML; never
  builds new files or folders for tweets. Automatically chooses the best existing
  section without asking and reports the choice afterward. Skip for general web
  reading (web-research) and for X sentiment research (last30days).
---

# Twitter Ingest

<core-instructions>

One job: turn a Twitter/X post into a source-card inside the existing archive at the path in `config/defaults.json`. The archive is the single destination — never create new files, folders, or "databases" for ingested tweets.

The archive is ~375 MB (base64 media inline). NEVER read it into context. Use the bundled script for all structural operations.

</core-instructions>

<workflow>

## Workflow

1. **Fetch the post** via the `web-research` skill (raw retrieval; tweets need JS rendering — Playwright/Lightpanda per its tool stack). Extract: author display name, handle, date, full text, media URLs, canonical status URL.
2. **Pick the section automatically.** If Ivo names an existing section, use it. Otherwise list the existing sections and choose the strongest topical match from the post or thread. Prefer the most specific applicable section when several fit. Never ask Ivo to classify an ingest; make the best reasonable choice and report it after insertion.

```bash
python3 "/Users/YOUR_USERNAME/.codex/skills/workflow skills/twitter-ingest/scripts/insert_card.py" --list-sections
```

3. **Build the card** matching the archive's exact format. Write it to a scratch file (session scratch dir, never `~/Files`):

```html
<article class="source-card" data-search="SECTION LABEL AUTHOR LOWERCASED TEXT">
    <div class="source-top">
        <div>
            <p class="section-chip">Section Name</p>
            <h3>Short descriptive label</h3>
        </div>
        <a class="source-link" href="https://x.com/USER/status/ID">Open source</a>
    </div>
    <p class="byline">Author · Month D, YYYY</p>
    <blockquote>Full tweet text.</blockquote>
</article>
```

   - `data-search`: section, label, author, and tweet text, lowercased.
   - Media: when practical, download and embed as `<details class="media-block"><summary>N media file(s)</summary><div class="media-grid"><img loading="lazy" src="data:image/jpeg;base64,..."></div></details>` before `</article>`. If media download fails, insert the card without media and say so.
   - Threads: one card per thread, full thread text in the blockquote, link to the first tweet.

4. **Insert** (idempotent — refuses duplicate URLs):

```bash
python3 "/Users/YOUR_USERNAME/.codex/skills/workflow skills/twitter-ingest/scripts/insert_card.py" --section SECTION_ID --card-file /path/to/card.html
```

   The script appends to the section's source list, bumps the section and nav counts, and rewrites atomically.

5. **Verify**: script exit 0 and its confirmation line. Report: section, label, URL, media yes/no.

</workflow>

<scope-control>

## Rules

- Never create a new archive, folder, or loose file — the existing archive is the only destination (standing rule since 2026-06-28).
- Never ask which section to use. Classify into the best existing section automatically and disclose the choice after insertion.
- Exit 3 means the URL is already archived — report that, do not force.
- New sections: only when Ivo explicitly asks; that is a manual edit to discuss first.

</scope-control>
