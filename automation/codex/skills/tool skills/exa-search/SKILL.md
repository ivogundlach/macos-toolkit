---
name: exa-search
description: >-
  Use when web-research needs Exa as a non-MCP execution method for semantic
  or niche web discovery, source diversification, query-relevant highlights,
  fresh search, or clean content extraction from known public URLs. Trigger
  when Ivo names Exa or when ordinary keyword discovery misses conceptually
  relevant sources. Keep web-research as the orchestrator for research tasks.
---

# Exa Search

Use the bundled standard-library CLI. It calls Exa's HTTPS API directly and
does not use MCP, another model, or an SDK dependency.

```bash
EXA="/Users/YOUR_USERNAME/.codex/skills/tool skills/exa-search/scripts/exa_cli.py"
python3 "$EXA" status
python3 "$EXA" search "query" --num-results 8
python3 "$EXA" contents "https://example.com/page"
```

Prefer the installed `exa-search` command when available. Run `status --live`
only for setup verification because it performs a small paid search request.

## Choose the operation

- Use `search` for semantic/niche discovery or a second discovery perspective.
- Default to extractive highlights to reduce tokens. Add `--content text` or
  `--content both` when full source text is necessary.
- Use `contents` only for known public URLs. Default to full extracted text;
  use `--mode highlights --highlights-query "..."` for bounded evidence.
- Add `--fresh` only when current page state matters; it forces live crawling
  and increases latency.
- Keep Exa `deep*` search types for deliberate structured discovery. Do not
  substitute Exa synthesis for web-research's independent source verification.

## Credentials and failures

Credential precedence is `EXA_API_KEY`, then macOS Keychain service
`exa-EXA_API_KEY`, then the legacy `last30days-EXA_API_KEY`. The environment
wins if it differs from Keychain. Never print or pass the key as a CLI argument.

To persist the current environment key deliberately:

```bash
exa-search auth-store
```

The CLI retries only transient network, 408, 429, and 5xx failures within its
declared attempt budget. On terminal failure it returns structured stderr with
the failure class and exact repair action. Report the failure under the global
recovery rule; do not silently replace Exa when its route was expected.

Keep raw JSON and extracted content in hidden research state. Do not save Exa
responses to Downloads or `/Users/YOUR_USERNAME/Files/`.
