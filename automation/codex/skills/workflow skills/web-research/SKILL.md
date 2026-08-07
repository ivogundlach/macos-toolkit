---
name: web-research
description: >-
  Use when a task needs any public-web search, page opening, supplied URL, documentation
  extraction, current-fact verification, product or option comparison,
  multi-source synthesis, deep research, research report, thesis-scale
  investigation, or legacy Storm Research request. Run one of two modes:
  normal web search for a narrow, targeted question answered comprehensively in
  chat, or deep research for broad adaptive fan-out and an automatically saved,
  citation-verified HTML report. Activate before the first web call and remain
  the orchestrator when Exa, Firecrawl, Lightpanda, Playwright, or browser
  control becomes the execution method. Skip when local files or memory already
  answer the request.
---

# Web Research

Use one evidence pipeline with two research scales. Keep discovery, source
acquisition, verification, and synthesis distinct.

Before the first web call, when the question concerns Ivo's own setup, tools,
projects, or past decisions, run `memory-semantic-query "<topic>"` (on PATH);
if the corpus already answers the request, skip the web entirely and open the
pointed-to file instead.

## Select the mode

### Normal web search

Default to normal mode for a specific fact, supplied URL, product decision,
comparison, troubleshooting question, or bounded investigation. Be narrow in
scope but comprehensive and detailed inside that boundary. Answer in chat with
citations. Create a document only when Ivo explicitly asks for one.

Examples:

- `Research X` -> normal.
- `Compare X and Y thoroughly` -> normal.
- `Which laptop should I buy?` -> normal.

Use 2-5 narrow query variants when needed. A source acquisition is one
successfully opened evidence-bearing source page; a raw fetch and a rendered
replacement of the same page count once, while search-result pages do not
count. Use a soft ceiling of 15 acquisitions. If reliable coverage would
materially exceed it, stop expanding scope and offer deep mode.

### Deep research

Use deep mode when Ivo says `deep research`, requests a graduation/thesis-scale
report, requests a subject to be covered completely, or says legacy `Storm
research`. A direct deep-mode request authorizes the bounded child-agent
pipeline and inherently requests its standalone HTML report.

Examples:

- `Deep research X` -> deep.
- `Write a graduation report on X` -> deep.
- `Storm research X` -> deep; Storm is only a legacy synonym.
- `Write a report on X` -> ask one short depth question when the expected scale
  is materially ambiguous.

For any other borderline request, default to normal and offer deep escalation.
In a non-interactive child or batch context, never wait for clarification:
default to normal, state the chosen boundary, and note deep availability. If a
document was explicitly requested, use the selected final destination
(Downloads by default; explicit path or project context wins).

## Discover and acquire evidence

1. Use native search for keyword, current-event, and broad discovery. Use Exa
   for semantic or niche discovery, a genuinely different source perspective,
   and query-relevant highlights. Do not call both mechanically for every
   query. Search results are leads, not proof; open the supporting sources.
2. For a known public URL, resolve `SKILL_DIR` to this skill directory and run
   the deterministic acquisition router:

   ```bash
   python3 "$SKILL_DIR/scripts/acquire_url.py" "URL"
   ```

   Read its JSON manifest first and then only the selected evidence. The router
   tries raw HTTP, Exa Contents, and Firecrawl at most once each under one
   method budget. It keeps evidence hidden for 14 days. If `notify_user` is
   true, disclose the failed default path and recovery or unresolved next step.
3. Never use a tool that runs another model over a page and returns only its
   summary when exact strings, completeness, redirects, content negotiation,
   structure, JavaScript rendering, or later verification matters.
4. Reuse source content already returned by Exa search when it satisfies the
   evidence need; do not immediately pay to reacquire the same representation.
   For exact delivery evidence or consequential claims, still inspect the
   source through the acquisition router or a primary representation.
5. Use Firecrawl directly for site maps, bounded crawls, batches, or structured
   extraction. If the router exhausts public acquisition, read
   [references/tool-stack.md](references/tool-stack.md) and escalate to the
   lightest capable browser path.
6. Keep authentication and UI work out of public acquisition scripts. When
   authentication is needed, use Ivo's existing signed-in Safari state or local
   Safari cookies automatically; use Firefox only as the secondary local source.
   Do not ask for separate cookie consent. Never export raw cookie values or put
   them in research evidence, manifests, reports, logs, or another service. Keep
   browser automation hidden unless Ivo asks to see it.

For every load-bearing source, know the final URL, status, content type,
redirect path, and whether the evidence was raw or rendered. Treat login pages,
consent walls, friendly errors, empty shells, malformed Markdown, and truncated
bodies as delivery failures, not requested content.

## Run normal mode

1. State the question boundary internally and keep adjacent issues out unless
   they materially change the answer.
2. Search with keyword-dense variants. Add Exa only when semantic discovery,
   niche coverage, or source diversification is likely to improve the result.
   Inspect authoritative sources plus the strongest material counterevidence.
3. Stop when further sources repeat existing evidence and every material claim
   is supported; do not inflate source count for appearance.
4. Cross-check consequential claims with two independent sources when
   practical. Report conflicts and uncertainty directly.
5. Lead with the answer, then give the detailed evidence, tradeoffs, and exact
   dates for time-sensitive claims. Cite URLs next to supported claims.
6. Assert that no document was created unless one was explicitly requested.

## Run deep mode

### Prepare the research map

1. Create a unique hidden run directory under
   `/Users/YOUR_USERNAME/.local/state/web-research/deep-runs/`.
2. Read [references/deep-research-framework.json](references/deep-research-framework.json).
3. Build 6-12 topic-specific workstreams. Consider definitions and scope,
   history, current evidence, theory, practice, economics and incentives,
   institutions and stakeholders, the strongest countercase, contradictions,
   and frontier gaps. Use only relevant dimensions and record material
   omissions with reasons.
4. Tell Ivo that deep research will run in bounded waves, verify claims, and
   automatically create a report in the selected destination (Downloads by
   default).

### Research, fill gaps, and verify

Run strictly sequential phases. Never start a new phase while child agents from
the prior phase remain active.

1. Run coverage workstreams in waves of at most three child agents. Require
   real source acquisition through this skill and concise structured evidence:
   core conclusion, strongest findings, source URLs, counterevidence, method
   limits, and unanswered questions.
   Use native search and Exa across the overall workstream set for discovery
   diversity; do not require both on every assignment. Use Firecrawl maps and
   crawls when a relevant site or documentation corpus needs bounded coverage.
2. Map contradictions, evidence quality, missing coverage, and the empirical
   question that would resolve the largest dispute.
3. Run at most three targeted gap-filling assignments when omissions are
   material.
4. Cluster load-bearing claims and run at most three independent verification
   assignments against primary sources. Correct, demote, or remove unsupported
   claims; never pad missing evidence.

Use at most 18 child-agent assignments before result review: 6-12 coverage,
up to 3 gap-filling, and up to 3 verification. The required independent result
review is one separate reviewer invocation, so the complete run uses at most 19
delegated/reviewer assignments. If coverage remains incomplete, disclose the
gap rather than claiming completeness.

### Render and review

Ask the deterministic renderer for its current input schema:

```bash
python3 "$SKILL_DIR/scripts/render_deep_report.py" --schema
```

Write the structured synthesis JSON in the hidden run directory. Judgment
belongs in the evidence and synthesis; repetitive HTML does not. Then run:

```bash
python3 "$SKILL_DIR/scripts/render_deep_report.py" "$RUN_DIR/report.json" --check-only
python3 "$SKILL_DIR/scripts/render_deep_report.py" "$RUN_DIR/report.json" --output "$RUN_DIR/draft.html"
```

Run the required independent `peer-review` result review on the hidden draft,
structured evidence, original request, and verification record. Resolve every
supported finding, rerun validation, and publish exactly once:

```bash
python3 "$SKILL_DIR/scripts/render_deep_report.py" "$RUN_DIR/report.json" --final --slug "topic-slug"
```

When Ivo explicitly names another destination or the report belongs inside an
existing project, add `--final-dir "PATH"`. Otherwise omit it so Downloads
remains the default.

The renderer owns escaping, repeated sections, verification counts, safe
filenames, exclusive collision handling, and the standalone design. It writes
the report to the selected final destination and keeps an identical recovery
copy beside the hidden JSON. Do not rebuild the HTML manually.

## Deliver

- Normal mode: return the detailed cited answer in chat and disclose source
  limits. If a document was explicitly requested, use the requested path or
  Downloads and return its exact clickable path.
- Deep mode: return the exact clickable report path printed by the renderer,
  verification tally, principal conclusion, sharpest contradiction, and major
  limitations. If Downloads was used, state that it is user-managed. In every
  case, state that a recoverable hidden copy remains at the printed recovery
  path.
- Never auto-open or foreground a report.
- Keep raw bodies, screenshots, drafts, and tool state hidden.
- Never expose API keys, cookies, bearer tokens, session identifiers, or other
  secrets.

## Handle path failure

- Treat same-method retry followed by equivalent evidence as a recovered
  transient. Record it; mention it only when material to confidence or cost.
- Treat a selected method differing from the default, source substitution, or
  representation loss as a route change. Tell Ivo what failed and what worked.
- When all suitable paths fail, attempt bounded safe repair, then report the
  failure, attempts, current blocker, and exact fix. Never silently omit a
  source, claim coverage, or continue with materially weaker evidence.
