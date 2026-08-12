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
```

## Citation Rules

- Lead with people, not publications. Prefer X handles, subreddits, YouTube channels, TikTok creators, Instagram creators, HN users, and Polymarket markets over articles when they support the same point.
- Hidden-link hosts (`CLAUDECODE` set): wrap labels as Markdown links with URLs from the raw dump.
- Visible-URL hosts (`CLAUDECODE` unset): use plain labels only. Keep raw URLs in hidden research state unless Ivo explicitly asks for them.
- Never chain weak citations. Pick the strongest source per claim.
- Never add a trailing sources block.

End after the useful synthesis. Do not append engine statistics, source counts,
top voices, raw-result paths, generic expertise claims, or follow-up invitations.
