# garak LLM Red-Team Report Template

## Assessment Information
- **Target Model / Endpoint**: [Name]
- **Date**: [YYYY-MM-DD]
- **Environment**: [local / staging / production / lab]
- **Authorization / Scope**: [Authorized scope and exclusions]
- **garak Version**: [version]

## Run Configuration
| Setting | Value |
|---|---|
| Generator / target type | |
| Target name / URI | |
| Probe families | |
| Detectors | |
| Generations | |
| Parallel attempts | |
| Report prefix | |

## Summary Verdict
| Risk Area | Status | Evidence |
|---|---|---|
| Prompt injection | Pass / Fail / Inconclusive | |
| Jailbreak | Pass / Fail / Inconclusive | |
| Leakage | Pass / Fail / Inconclusive | |
| Toxicity / misuse | Pass / Fail / Inconclusive | |

## Probe Results
| Probe | Detector | Attempts | Pass Rate | Failure Examples | Severity |
|---|---|---:|---:|---|---|
| | | | | | |

## Confirmed Findings
| Severity | Finding | Successful Prompt / Evidence | Impact | Recommended Fix |
|---|---|---|---|---|
| Critical / High / Medium / Low | | | | |

## Mitigation And Re-Test
| Control Applied | Re-Test Prefix | Before | After | Result |
|---|---|---:|---:|---|
| | | | | |

## Artifacts
- garak report JSONL:
- garak report HTML:
- garak log:
- Hit log:

## Open Questions
- [ ] Were token costs and rate limits acceptable?
- [ ] Which failures are reproducible outside garak?
- [ ] Which controls should become CI regression gates?
