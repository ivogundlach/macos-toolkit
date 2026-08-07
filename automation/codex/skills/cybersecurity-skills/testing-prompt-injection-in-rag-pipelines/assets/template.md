# RAG Prompt-Injection Test Report Template

## Assessment Information
- **Target RAG App**: [Name]
- **Date**: [YYYY-MM-DD]
- **Environment**: [dev / staging / production / lab]
- **Authorization / Scope**: [Authorized scope and exclusions]
- **Retriever / Vector Store**: [FAISS / Chroma / Pinecone / Milvus / pgvector / other]
- **Embedding Model**: [Model]

## Retrieval Surface
| Ingestion Path | User-Controlled? | Trust Boundary | Notes |
|---|---|---|---|
| Documents | Yes / No | | |
| Web pages | Yes / No | | |
| Tickets / email | Yes / No | | |
| Internal wiki | Yes / No | | |

## Test Configuration
| Tool | Test Set / Plugin | Target | Output Artifact |
|---|---|---|---|
| garak | | | |
| Promptfoo | | | |
| PyRIT | | | |
| Embedding poison PoC | | | |

## Findings
| Severity | Finding | Attack Path | Evidence | Recommended Control |
|---|---|---|---|---|
| Critical / High / Medium / Low | | | | |

## Evidence
| Evidence Type | Artifact / Excerpt | Notes |
|---|---|---|
| Retrieved chunk | | |
| Model response | | |
| Scorer output | | |
| Embedding similarity | | |

## Mitigations
- [ ] Separate untrusted retrieved text from instructions.
- [ ] Add retrieved-content injection detection.
- [ ] Add output leakage checks.
- [ ] Restrict document ingestion sources.
- [ ] Add regression tests for confirmed attacks.

## Open Questions
- [ ] Which documents or tenants were in scope?
- [ ] Which model and retriever versions were tested?
- [ ] Which findings need re-test after mitigation?
