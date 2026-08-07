# LLM Guardrails Defense Report Template

## Assessment Information
- **System / App**: [Name]
- **Date**: [YYYY-MM-DD]
- **Owner**: [Team / person]
- **Environment**: [dev / staging / production / lab]
- **Scope**: [Authorized scope and exclusions]

## Guardrail Architecture
| Layer | Control | Purpose | Status |
|---|---|---|---|
| Input | | Block injection, jailbreaks, secrets, unsafe requests | Not tested |
| Retrieval / Context | | Filter or isolate untrusted context | Not tested |
| Tool Use | | Constrain tools and arguments | Not tested |
| Output | | Block leakage, toxicity, unsafe completion | Not tested |
| Logging / Review | | Preserve evidence and audit trail | Not tested |

## Test Corpus
| Corpus | Source | Count | Purpose |
|---|---|---|---|
| Jailbreak prompts | | | |
| Prompt injection prompts | | | |
| Sensitive-data leakage prompts | | | |
| Off-topic / policy-boundary prompts | | | |

## Results
| Test Class | Attempts | Blocked | Allowed | Bypass Rate | Evidence |
|---|---:|---:|---:|---:|---|
| Jailbreak | | | | | |
| Prompt injection | | | | | |
| Sensitive output | | | | | |
| Tool misuse | | | | | |

## Findings
| Severity | Finding | Evidence | Recommended Control | Owner |
|---|---|---|---|---|
| Critical / High / Medium / Low | | | | |

## Recommended Changes
- [ ] Add or tune input scanners.
- [ ] Add or tune output scanners.
- [ ] Add retrieval/context isolation.
- [ ] Add tool-call allowlists or argument validation.
- [ ] Add regression tests for confirmed bypasses.

## Open Questions
- [ ] Which model, prompt, or retriever versions were tested?
- [ ] Which failures are accepted risk?
- [ ] Who owns ongoing regression testing?
