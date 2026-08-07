# last30days Comparison Output Template

Use this template for COMPARISON queries. Read `references/voice-contract.md` before using it.

```markdown
🌐 last30days v{VERSION} · synced {YYYY-MM-DD}

# {TOPIC_A} vs {TOPIC_B} [vs {TOPIC_C}]: What the Community Says (/Last30Days)

## Quick Verdict

{One paragraph. Frame the thesis: competitors, layers of a stack, dominant option, challenger, or unclear split. Include comparable scale stats when available. End with one quotable community framing from a tweet, Reddit comment, YouTube clip, or other primary discussion.}

## {Entity 1}

**Community Sentiment:** {Positive / Mixed / Negative / Enthusiastic / Security-concerned / etc.} ({N}+ mentions across {source list})

{Optional pitch-vs-pulse sentence. Include only if resolved positioning was captured for this entity and the month's evidence directly supports a specific claim, cuts against one, or is squarely about the pitched ground. Otherwise omit this line entirely.}

**Strengths (what people love)**
- {Specific strength with source attribution}
- {Specific strength with source attribution}
- {Specific strength with source attribution}

**Weaknesses (common complaints)**
- {Specific complaint with source attribution}
- {Specific complaint with source attribution}

## {Entity 2}

**Community Sentiment:** {Positive / Mixed / Negative / Enthusiastic / Security-concerned / etc.} ({N}+ mentions across {source list})

{Optional pitch-vs-pulse sentence, or omit entirely.}

**Strengths (what people love)**
- {Specific strength with source attribution}
- {Specific strength with source attribution}
- {Specific strength with source attribution}

**Weaknesses (common complaints)**
- {Specific complaint with source attribution}
- {Specific complaint with source attribution}

## {Entity 3}

{Use the same structure when a third entity exists. Omit the whole section otherwise.}

## Head-to-Head

| Dimension | {Entity 1} | {Entity 2} | {Entity 3} |
|---|---|---|---|
| What it is | ... | ... | ... |
| GitHub stars | ... | ... | ... |
| Philosophy | ... | ... | ... |
| Skills | ... | ... | ... |
| Memory | ... | ... | ... |
| Models | ... | ... | ... |
| Security | ... | ... | ... |
| Best for | ... | ... | ... |
| Install | ... | ... | ... |

{Fill cells with 5-15 words. If an axis does not apply, write `N/A` or a topic-appropriate substitute. Ground `What it is` in resolved positioning when captured.}

## The Bottom Line

**Choose {Entity 1} if** {specific use case, comfort profile, or tradeoff}. {One supporting sentence with attribution.}

**Choose {Entity 2} if** {specific use case, comfort profile, or tradeoff}. {One supporting sentence with attribution.}

**Choose {Entity 3} if** {specific use case, comfort profile, or tradeoff}. {One supporting sentence with attribution.}

## The emerging stack

{One paragraph. Name the combination pattern the community is converging on and cite specific sources. If the data does not support an emerging-stack observation, write: "No emerging stack pattern has crystallized in the research window yet."}

---
✅ All agents reported back!
{engine footer copied verbatim}

---
I've compared {TOPIC_A} vs {TOPIC_B} [vs {TOPIC_C}] using the latest community data. Some things you could ask:
- Deep dive into {Entity 1} alone with /last30days {Entity 1}
- Deep dive into {Entity 2} alone with /last30days {Entity 2}
- Focus on {specific dimension} from the Head-to-Head table
- Look at a different time period with --days=7 or --days=90
```

## Do Not

- Do not use `What I learned:`.
- Do not use bold-lead-in paragraphs as the main body.
- Do not add `KEY PATTERNS from the research:`.
- Do not fabricate a `## Notable Stats` block.
- Do not add any `##` headers beyond the comparison allowlist in `references/voice-contract.md`.
- Do not add a trailing sources block.

