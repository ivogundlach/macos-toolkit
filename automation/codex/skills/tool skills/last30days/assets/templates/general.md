# last30days General Output Template

Use this template for GENERAL, NEWS, PROMPTING, and RECOMMENDATIONS outputs. Read `references/voice-contract.md` before using it.

## GENERAL / NEWS / PROMPTING

```markdown
🌐 last30days v{VERSION} · synced {YYYY-MM-DD}

What I learned:

**{Specific newsy headline}** - {1-2 sentences about what people are actually saying. Cite sparingly with host-appropriate labels or links.}

**{Specific newsy headline}** - {1-2 sentences with a second distinct theme. Weave in attributed community comments when available.}

**{Specific newsy headline}** - {1-2 sentences with a third distinct theme or tension.}

KEY PATTERNS from the research:
1. {Pattern grounded in the evidence} - per {strong source label}
2. {Pattern grounded in the evidence} - per {strong source label}
3. {Pattern grounded in the evidence} - per {strong source label}

---
✅ All agents reported back!
{engine footer copied verbatim}

---
I'm now an expert on {TOPIC}. Some things I can help with:
- {Specific follow-up based on the biggest finding}
- {Specific practical or creative application from the evidence}
- {Specific deeper dive into a pattern or debate}

I have all the links to the {N} {source list} I pulled from. Just ask.
```

## RECOMMENDATIONS

Use signal quality, not mention count alone. Separate sub-categories when the query implies different jobs such as production scale, learning, benchmarks, or personal use.

```markdown
🌐 last30days v{VERSION} · synced {YYYY-MM-DD}

What I learned:

**{Recommendation thesis}** - {Explain what the evidence supports and why. Mention the strongest specific signal, not just volume.}

**{Tradeoff or category split}** - {Explain who should choose what. Use host-appropriate citation labels.}

KEY PATTERNS from the research:
1. **{Pick or category}** - {Why it belongs here, with source support}
2. **{Pick or category}** - {Why it belongs here, with source support}
3. **{Pick or category}** - {Why it belongs here, with source support}

Notable mentions: {Only include items that appeared but do not deserve recommendation status. Say why.}

---
✅ All agents reported back!
{engine footer copied verbatim}

---
I'm now an expert on {TOPIC}. Want me to go deeper? For example:
- {Compare two specific items from the results}
- {Explain why a specific item is trending}
- {Help the user get started with a specific item}

I have all the links to the {N} {source list} I pulled from. Just ask.
```

## Citation Rules

- Lead with people, not publications. Prefer X handles, subreddits, YouTube channels, TikTok creators, Instagram creators, HN users, and Polymarket markets over articles when they support the same point.
- Hidden-link hosts (`CLAUDECODE` set): wrap labels as Markdown links with URLs from the raw dump.
- Visible-URL hosts (`CLAUDECODE` unset): use plain labels only. Leave URLs to the footer and saved raw file.
- Never chain weak citations. Pick the strongest source per claim.
- Never add a trailing sources block.

## Invitation Variants

PROMPTING:

```markdown
---
I'm now an expert on {TOPIC} for {TARGET_TOOL}. What do you want to make? For example:
- {Specific idea based on a popular technique}
- {Specific idea based on a trending style or approach}
- {Specific idea based on what people are actually creating}

Just describe your vision and I'll write a prompt you can paste straight into {TARGET_TOOL}.
```

NEWS:

```markdown
---
I'm now an expert on {TOPIC}. Some things you could ask:
- {Specific follow-up about the biggest story}
- {Question about implications of a key development}
- {Question about what might happen next based on the current trajectory}
```

GENERAL:

```markdown
---
I'm now an expert on {TOPIC}. Some things I can help with:
- {Specific question based on the most discussed aspect}
- {Specific creative or practical application}
- {Deeper dive into a pattern or debate}
```

