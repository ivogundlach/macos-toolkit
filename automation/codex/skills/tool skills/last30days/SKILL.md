---
name: last30days
description: >-
  Use when Ivo asks to research what people actually say now or recently about a
  topic, product, person, market, tool, policy, community, recommendation, hiring
  signal, or comparison over roughly the last 30 days. Trigger on phrases like
  "last30days", "what are people saying about X", "last 30 days reaction",
  "recent Reddit/X/YouTube sentiment", "community reaction", "compare A vs B
  from recent discussion", or broad current social/web discourse where Reddit, X,
  YouTube, TikTok, Hacker News, Polymarket, GitHub, or web chatter matter.
  Operates under the web-research gate (AGENTS.md §1): web-research is the
  orchestrator and this engine is its execution method for multi-platform social
  aggregation. When the engine cannot cover a needed source or exact current
  fact, defer to web-research's other retrieval methods (raw-bytes fetch,
  Firecrawl, Playwright) rather than a summarizing fetch.
allowed-tools: Bash, Read, Write, AskUserQuestion, WebSearch
license: MIT
metadata:
  version: "3.8.3"
  argument_hint: "last30days nvidia earnings reaction | last30days AI video tools | last30days what users want in react"
  homepage: https://github.com/mvanhorn/last30days-skill
  repository: https://github.com/mvanhorn/last30days-skill
  author: mvanhorn
  user_invocable: true
  openclaw:
    emoji: "📰"
    requires:
      env: []
      optionalEnv:
        - SCRAPECREATORS_API_KEY
        - OPENAI_API_KEY
        - XAI_API_KEY
        - OPENROUTER_API_KEY
        - PERPLEXITY_API_KEY
        - PARALLEL_API_KEY
        - BRAVE_API_KEY
        - APIFY_API_TOKEN
        - AUTH_TOKEN
        - CT0
        - BSKY_HANDLE
        - BSKY_APP_PASSWORD
        - TRUTHSOCIAL_TOKEN
      bins:
        - node
        - python3
    primaryEnv: SCRAPECREATORS_API_KEY
    files:
      - "scripts/*"
    homepage: https://github.com/mvanhorn/last30days-skill
    tags:
      - research
      - deep-research
      - reddit
      - x
      - twitter
      - youtube
      - tiktok
      - instagram
      - linkedin
      - hackernews
      - polymarket
      - digg
      - bluesky
      - truthsocial
      - trends
      - recency
      - news
      - citations
      - multi-source
      - social-media
      - analysis
      - web-search
      - hiring-signals
      - ai-skill
      - clawhub
---
# Last30Days

Run the bundled deterministic engine for recent community and social-web
research. `web-research` remains the orchestrator: Last30Days is its specialized
multi-platform execution method, while web-research supplies other raw,
rendered, or exact-current retrieval when this engine cannot cover a source.

Do not improvise a generic "last 30 days" search. Run the engine, read its full
evidence, and preserve the output contract.

## Required resources

Read only what the current path needs:

| Need | Required resource |
|---|---|
| Every synthesis | [voice-contract.md](references/voice-contract.md) and the matching [general](assets/templates/general.md) or [comparison](assets/templates/comparison.md) template |
| First run, setup, Python selection, permissions, or provider configuration | [setup-and-runtime.md](references/setup-and-runtime.md) |
| Named entities, ambiguous names, comparisons, competitors, hiring signals, handles, repositories, or query-plan construction | [query-planning.md](references/query-planning.md) |
| Advanced execution, evidence weighting, HTML, follow-ups, prompt generation, or security details | [advanced-modes.md](references/advanced-modes.md) |
| Diagnosing a recurring output-shape failure | [regression-history.md](references/regression-history.md) |
| User-requested HTML brief | [save-html-brief.md](references/save-html-brief.md) |

Read `config/defaults.json` when destination or engine defaults matter.

## Hot-path contract

These requirements remain local because each prevents an observed regression:

1. Resolve `SKILL_DIR` from the `SKILL.md` that actually activated; run the
   sibling `scripts/last30days.py`. Never discover and execute a different copy.
2. Run the engine. A web-only response is not equivalent and must never be
   presented as complete Last30Days research.
3. Use `--emit=compact` for the normal path. `--emit=md` is diagnostic, not the
   user-facing workflow.
4. When a reasoning host has web search, it is the planner: resolve relevant
   entities and pass a query-plan file with `--plan`. Never run a bare keyword
   command for a named entity. The engine never calls Gemini or another model
   for planning, reranking, or scoring; it uses host inference plus deterministic
   local ranking. Without a host search path, use `--auto-resolve`.
5. Anchor every subquery for collision-prone names with company, role, product,
   or domain context. A bare common name is a known off-topic failure.
6. Pass the plan through a temporary file, not inline single-quoted JSON or an
   outer single-quoted `bash -lc`/`zsh -lc` wrapper; apostrophes in queries must
   not break execution.
7. Read the complete engine output. Synthesize evidence; never emit ranked
   evidence clusters verbatim.
8. Preserve the engine badge. GENERAL/NEWS/PROMPTING/
   RECOMMENDATIONS output begins with `What I learned:` after the badge and has
   no invented title or body section headers. COMPARISON uses only the approved
   comparison headers.
9. Never append a trailing Sources/References/URL block. Cite according to the
   active host and keep the raw report hidden unless Ivo explicitly asks for it.
   Never expose engine statistics, source-count trees, top voices, raw-result
   paths, generic expertise claims, or follow-up invitations.
10. Weave at least two attributed community comments into the narrative when
    the evidence supplies them. Do not narrate tool health or engine noise.
11. First-party posts are primary evidence when relevant. Recommendation
    ranking follows practitioner/expert/measurable signal, not mention count.
12. HTML is created only when requested. Save locally first; publishing remains
    a separate explicit action.
13. Detect keyword traps such as demographic shopping phrases, numeric/age
    phrases, overly literal how-to wording, or generic single nouns. Reframe or
    ask one focused question before running the engine instead of researching a
    phrase nobody naturally uses.
14. For person topics, resolve X handle, GitHub user, relevant subreddits, and
    related voices unless the resolution step explicitly found no account. An
    X-only person query is a known thin-corpus failure.
15. Match citation style to the host: use inline Markdown links when URLs stay
    hidden; on visible-URL hosts use readable source labels and leave raw URLs
    in the hidden report. Never reconstruct a comment URL.
16. The selected Last30Days voice contract and template override conflicting
    global prose preferences for this skill, including their required bold
    lead-ins and punctuation rules.

## Runtime preflight

1. Set `SKILL_DIR` to the directory containing this loaded file.
2. Resolve Python 3.12 or newer. Prefer an existing `LAST30DAYS_PYTHON`, then
   `python3.14`, `python3.13`, `python3.12`, `python3`, or `python`; verify
   `sys.version_info >= (3, 12)` before use.
3. Set backend report state to
   `${LAST30DAYS_MEMORY_DIR:-$HOME/.local/state/last30days/reports}`. Raw
   research is hidden state, never a Downloads deliverable.
4. Run:

```bash
"$LAST30DAYS_PYTHON" "$SKILL_DIR/scripts/last30days.py" --preflight
```

Preflight is read-only and does not expose cookie values. If it reports an
unconfigured first run, read `setup-and-runtime.md` and follow the matching host
flow. Existing local cookies are authorized automatically for this retrieval:
Safari first, Firefox second. Keep values in memory and secret. Chromium stays
opt-in because it may trigger Keychain UI. Respect `--no-browser-cookies` or
`FROM_BROWSER=off` when Ivo opts out.

If Python 3.12+ is unavailable, report the exact installation action and stop.
Do not silently substitute a WebSearch-only report. If Full Disk Access blocks
Safari cookies, surface the macOS setting path, attempt one bounded retry when
appropriate, then continue only with an explicitly disclosed coverage change.

## Parse the request

Determine:

- `TOPIC`: the research subject, excluding skill-level output switches;
- `LOOKBACK_DAYS`: 30 unless Ivo requests another period;
- query type: GENERAL, NEWS, RECOMMENDATIONS, COMPARISON, or PROMPTING;
- optional modes such as `--competitors`, `--hiring-signals`, `--deep-research`,
  HTML, ELI5, or a historical `--as-of` window.

Do not forward skill-level switches like HTML intent as unknown engine
arguments. Read `query-planning.md` for named entities, comparisons, competitor
fan-out, hiring signals, or ambiguous handles/repositories. Paid deep-research
providers require the applicable authorization and configured credential.

## Build the plan

On a host with web search, generate one to four subqueries and write the JSON to
a temporary file. The primary subquery includes Reddit, X, YouTube, TikTok,
Instagram, Hacker News, and Polymarket. Secondary queries may narrow sources.
Use concise keyword-heavy `search_query` values, natural-language
`ranking_query` values, no temporal/meta-research filler, and weights from 1.0
for primary to 0.3-0.8 for secondary angles.

Minimum schema:

```json
{
  "intent": "opinion",
  "freshness_mode": "balanced_recent",
  "cluster_mode": "none",
  "subqueries": [
    {
      "label": "primary",
      "search_query": "anchored topic terms",
      "ranking_query": "What are people actually saying about the topic?",
      "sources": ["reddit", "x", "youtube", "tiktok", "instagram", "hackernews", "polymarket"],
      "weight": 1.0
    }
  ]
}
```

For comparison, create one query per entity plus a head-to-head query. Resolve
and pass applicable `--x-handle`, `--x-related`, `--subreddits`,
`--dedicated-subreddits`, TikTok/Instagram creator or hashtag, GitHub user/repo,
and Polymarket disambiguation flags. Omit unresolved values; never invent them.

## Execute in the foreground

Write the plan using a quoted heredoc directly in the shell tool:

```bash
QUERY_PLAN_FILE=$(mktemp "${TMPDIR:-/tmp}/last30days-plan.XXXXXX")
trap 'rm -f "$QUERY_PLAN_FILE"' EXIT
cat >| "$QUERY_PLAN_FILE" <<'PLAN_EOF'
{QUERY_PLAN_JSON}
PLAN_EOF

"$LAST30DAYS_PYTHON" "$SKILL_DIR/scripts/last30days.py" "$TOPIC" \
  --days "$LOOKBACK_DAYS" \
  --emit=compact \
  --plan "$QUERY_PLAN_FILE" \
  --save-dir "$LAST30DAYS_MEMORY_DIR" \
  "${TARGETING_FLAGS[@]}"
```

Run in the foreground with a five-minute ceiling so the complete evidence is
available for synthesis. Without host web search, omit `--plan` and add
`--auto-resolve`. Use `LAST30DAYS_NATIVE_SEARCH=1` only when web-research will
provide a stronger host supplement; otherwise retain the engine's keyless web
floor. The engine's configured web grounding may use Exa without MCP.

After the engine completes, let `web-research` add targeted primary/raw/rendered
sources when exact current facts, missing platforms, or narrower verification
requires them. This supplement does not replace the engine and must remain
within the user's research scope.

## Synthesize and verify

Read the complete compact output, including evidence clusters, top comments,
best takes, and source coverage. Ground every
claim in retrieved evidence and distinguish thin or conflicting support.

Before writing, read `voice-contract.md` and the matching output template.
Before emitting, verify badge, allowed structure, community voice, lack of tool
meta-commentary, no internal statistics or paths, and no trailing sources block. Regenerate once
when the evidence supports correcting a failed check; otherwise disclose the
missing evidence rather than fabricating it.

If the user requested HTML, read `save-html-brief.md`, render to the required
collision-safe Downloads path, and verify the file. Never publish or upload
without a separate explicit choice.

## Failure and security contract

- Never expose or persist raw cookies, API keys, session tokens, or update keys.
- Never post, like, follow, or modify platform content.
- Classify missing optional coverage separately from engine failure. Attempt
  bounded repair and disclose any unresolved or materially different route.
- Do not claim complete multi-platform research when the engine did not run or
  when a required source silently failed.
- Keep raw reports and caches in hidden state. Only requested user-facing HTML
  belongs in Downloads.
- For setup, advanced weighting, prediction markets, follow-up prompts, and
  platform-specific permissions, read `advanced-modes.md`.
