# Web Research Tool Stack

Read this when choosing or escalating an acquisition method. Do not run every
tool. Use the lightest one that can preserve the evidence the answer needs.

| Tool | Purpose | Use when |
|---|---|---|
| Native search | Discover candidate sources and vocabulary | Starting a query or locating the authoritative page. Search snippets are leads, not evidence. |
| Exa | Semantic discovery and clean highlights/content | Keyword search misses conceptual matches, a second discovery perspective is useful, or a known URL needs single-page extraction. |
| `scripts/acquire_url.py` | Acquire one known public URL through a bounded fallback chain | Default known-URL path. It records raw → Exa → Firecrawl attempts and route-change notification state. |
| `scripts/fetch_url.py` | Capture one public page's exact raw delivery evidence | Called by the router; use directly only when raw-only behavior or exact transport debugging is required. |
| Firecrawl | Managed extraction, site maps, batches, and bounded crawling | A site or documentation section needs mapping/crawling, structured extraction, or harder public acquisition. |
| Trafilatura | Clean already-acquired HTML locally | The correct HTML is complete but navigation and boilerplate obscure the article text. |
| Lightpanda | Render public JavaScript pages cheaply | Raw HTML is only an application shell and full visual browser fidelity is unnecessary. |
| Playwright or browser control | Full browser behavior | Authentication, clicking, forms, downloads, screenshots, visual verification, or lighter rendering failure. |
| Spider or link map | Discover a site's structure | Pages must be mapped before targeted acquisition. Link maps are not evidence. |
| `scripts/render_deep_report.py` | Build and validate deep-research HTML | Verified structured synthesis is ready; the renderer replaces repetitive hand-written markup. |

## Acquisition counting

A source acquisition is one successfully opened evidence-bearing page. A raw
capture and a later rendered replacement of the same URL count once. Search
results, link maps, failed deliveries, consent pages, and empty shells do not
count as acquired evidence. Normal mode has a soft ceiling of 15 acquisitions;
deep mode controls breadth through its workstream and assignment budgets.

## Escalation rules

1. Start with native search for ordinary discovery. Add Exa for semantic/niche
   discovery or source diversity, not as a mandatory duplicate search.
2. Use `scripts/acquire_url.py` for known public HTTP(S) pages. It owns the
   raw → Exa Contents → Firecrawl single-page fallback budget.
3. Use Firecrawl directly for structured extraction, mapping, batches, or
   bounded multi-page work.
4. Use Trafilatura when local cleanup of already complete HTML alone solves the
   problem.
5. Use Lightpanda for public JavaScript rendering after extraction paths fail.
6. Use Playwright or authenticated browser control only for interaction,
   authentication, visual state, or failure of lighter methods.

Do not use MCP servers. Do not choose a browser merely because the request says
`open` or `go to`.

## Diagnose a failed path

Use deterministic checks before guessing:

```bash
exa-search status
firecrawl --status
command -v lightpanda playwright-cli
```

Use `exa-search status --live` only when local credential presence is
insufficient; it performs a real API request. Preserve the failing command's
exit code and stderr in hidden state. Attempt the indicated repair once, then
follow the acquisition manifest and global notification rule.

## Integrity rules

- A raw body with little answer-bearing text plus an app root or loading marker
  is evidence to render once, not proof that content is absent.
- Inspect binary, PDF, or unsupported content with the appropriate local format
  tool or reacquire it with a capable extractor.
- Use advertised `llms.txt`, Markdown, or alternate document representations
  when available; do not send speculative Markdown `Accept` headers broadly.
- For authenticated work, use the existing signed-in surface. Never copy
  credentials into raw helpers or reports.
- Respect site terms, rate limits, and robots policies for repeated requests.
- Preserve redirects, soft errors, truncation, content-type mismatches, malformed
  structure, and representation changes whenever they affect the answer.
- Do not treat Exa or Firecrawl summaries, structured synthesis, or agent output
  as raw evidence. Prefer extractive highlights/full text and verify
  consequential claims against opened sources.
- The acquisition manifest's `notify_user` flag is binding: report a changed or
  exhausted route with the failure and repair information instead of silently
  degrading.
