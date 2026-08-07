---
name: firecrawl
description: >-
  Use when web-research needs Firecrawl as the execution method for public-web search,
  scraping, mapping, crawling, structured extraction, page interaction, downloading web
  content, or parsing local documents with the Firecrawl CLI. Trigger on Firecrawl by
  name, scrape/crawl/map requests, hydrated pages, structured web data, or durable local
  extraction outputs.
---
# Firecrawl

## Related Skills

- Use `web-research` first for public-web research, known-URL extraction, current-fact verification, or multi-source synthesis. Firecrawl is an execution method inside that workflow.

Use the local `firecrawl` CLI for web extraction when it is better than ordinary browsing: JS-rendered pages, full-page markdown, search plus hydrated results, site maps, crawls, structured extraction, browser interaction, or durable local outputs.

Check setup when needed:

```bash
firecrawl --status
```

If Firecrawl is not installed or authenticated, report that directly or use normal web tools when they satisfy the request.

## Choose The Command

| Need | Command |
| --- | --- |
| Find sources from a query | `firecrawl search` |
| Extract known URLs | `firecrawl scrape` |
| Find pages on a known domain | `firecrawl map` |
| Bulk extract a site or docs section | `firecrawl crawl` |
| Extract structured data from complex sites | `firecrawl agent` or `scrape --schema-file` |
| Click, fill forms, paginate, or use browser state | `firecrawl interact` after an initial scrape |
| Save a site locally | `firecrawl experimental download` or `firecrawl x download` |
| Parse local PDF/DOCX/XLSX/HTML files | `firecrawl parse` |

## Command Patterns

Save large extraction/cache outputs under `.firecrawl/` instead of streaming them into chat or terminal. These `.md` examples are internal scrape artifacts, not user-facing report/doc deliverables; final reports/docs should still use standalone HTML unless the user asks otherwise.

```bash
mkdir -p .firecrawl
firecrawl search "query" --limit 5 --json -o .firecrawl/search.json
firecrawl search "query" --scrape --limit 3 --json -o .firecrawl/search-pages.json
firecrawl scrape "https://example.com/page" -o .firecrawl/page.md
firecrawl scrape "https://example.com/page" --format markdown,links --json -o .firecrawl/page.json
firecrawl map "https://example.com" --search "authentication" -o .firecrawl/map.txt
firecrawl crawl "https://example.com/docs" --limit 50 --wait -o .firecrawl/crawl.json
firecrawl scrape "https://example.com/pricing" --schema-file schema.json --json -o .firecrawl/pricing.json
firecrawl agent "extract all pricing tiers from example.com as JSON" --wait -o .firecrawl/agent.json
firecrawl parse "/path/to/file.pdf" -o .firecrawl/file.md
```

For interaction, scrape first to establish the target/session:

```bash
firecrawl scrape "https://example.com" --profile default -o .firecrawl/start.md
firecrawl interact "click pricing, open enterprise details, extract visible plan names"
```

## Operating Rules

- Prefer primary sources and exact URLs for factual answers.
- Use `--tbs qdr:d|qdr:w|qdr:m|qdr:y` for freshness-sensitive search.
- Use `--country` or `--location` when geography changes results.
- Use `--profile` only for legitimate authenticated access.
- Add or recommend `.firecrawl/` in `.gitignore` when writing cache files inside a repo.
- Do not paste full scraped pages into the final response; summarize and cite source URLs.
- Do not use Firecrawl to bypass access controls or collect data the user is not allowed to access.
