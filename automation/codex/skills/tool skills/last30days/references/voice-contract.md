# last30days Voice Contract

Read this file before synthesizing any `/last30days` response. This contract wins over global writing preferences while the skill is active.

## Mandatory Badge

The first line of every response is the engine badge:

```text
🌐 last30days v{VERSION} · synced {YYYY-MM-DD}
```

Then emit one blank line. For GENERAL, NEWS, PROMPTING, and RECOMMENDATIONS queries, line 3 is exactly:

```text
What I learned:
```

For COMPARISON queries, line 3 is:

```text
# {TOPIC_A} vs {TOPIC_B} [vs {TOPIC_C}]: What the Community Says (/Last30Days)
```

## Laws

1. No trailing `Sources:`, `References:`, `Further reading:`, `Citations:`, URL list, or publication-name dump. The engine footer and saved raw file carry citation traceability.
2. No invented title line for GENERAL, NEWS, PROMPTING, or RECOMMENDATIONS. The badge is the title. COMPARISON is the only exception and must use the comparison title above.
3. No em dashes or en dashes. Use ` - ` with spaces. Quoted source text may preserve source punctuation.
4. No `##` or `###` section headers in GENERAL, NEWS, PROMPTING, or RECOMMENDATIONS body text. Use bold-lead-in paragraphs, then `KEY PATTERNS from the research:` and a numbered list. COMPARISON is the only exception and may use only the template headers.
5. Pass through the engine footer verbatim. The footer begins with `✅ All agents reported back!`, is bounded by `---` lines, and belongs after the synthesis body and before the invitation.
6. Never dump raw ranked evidence clusters. Read `## Ranked Evidence Clusters`, `## Stats`, `## Source Coverage`, `## Top Community Comments`, and `## Best Takes` as evidence for synthesis, not text to emit.
7. On named-entity topics, the reasoning model is the planner. Generate the plan and pass it to the engine with `--plan "$QUERY_PLAN_FILE"` instead of running a bare keyword-only engine call.
8. Cite readably for the current host. If `CLAUDECODE` is set, inline-link citations with `[label](url)`. If it is unset, use plain source labels such as `per @handle`, `per r/subreddit`, or `per Rolling Stone`. Never emit raw URL strings in narrative prose.
9. Weave the community voice. If the evidence contains top comments or best takes, include at least two verbatim, attributed community comments inside the narrative. Do not create a separate comments section. Do not narrate engine behavior or tool health.
10. Treat first-party posts as first-class evidence. On person topics, the subject's own posts and direct interactions are primary signal when present.

## Comparison Header Allowlist

Comparison output may use only these `##` headers:

- `## Quick Verdict`
- `## {Entity}` once per compared entity
- `## Head-to-Head`
- `## The Bottom Line`
- `## The emerging stack`

Any other `##` header is a LAW 4 violation.

## Synthesis Self-Check

Before emitting, check:

- The badge is line 1.
- GENERAL, NEWS, PROMPTING, and RECOMMENDATIONS use `What I learned:` and no custom title.
- The body has no unauthorized `##` or `###` headers.
- The body has no em dash or en dash characters.
- The synthesis includes at least two attributed community quotes when the evidence provides them.
- The synthesis says nothing about engine failures, source-column noise, name collisions, or other tooling behavior.
- The engine footer appears verbatim when present.
- The response ends at the invitation. There is nothing below it.

