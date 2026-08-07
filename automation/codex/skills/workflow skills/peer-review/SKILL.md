---
name: peer-review
description: >-
  Use for evidence-first adversarial review of code changes, plans, completed
  work, or incoming review feedback. Trigger when Ivo asks to review, verify,
  red-team, or get a second opinion on a branch, PR, diff, implementation, plan,
  result, reviewer comment, or linter complaint. Also use when the concrete
  high-risk review conditions in AGENTS.md require independent review. Select
  code, plan, result, or feedback mode.
---

# Peer Review

Remain accountable for the final judgment. Treat every reviewer claim as a hypothesis until the artifact supports it.

## Select the mode

| Mode | Input | Outcome |
|---|---|---|
| `code` | A branch, PR, commit range, or working-tree diff | Prioritized, actionable code findings |
| `plan` | An implementation plan | Adversarial critique and revise/proceed recommendation |
| `result` | Completed work plus verification evidence | Independent completion assessment |
| `feedback` | Review comments, PR feedback, or linter complaints | Verified fixes, clarification requests, or evidence-based rejections |

Use one mode unless the request clearly combines them. `AGENTS.md` determines when independent review is required; this skill defines how the review is performed.

## Shared Review Rules

1. Inspect the actual artifact and enough local context to understand it. Do not review from a summary when the source is available.
2. Read the applicable `AGENTS.md`, repository instructions, requirements, tests, types, schemas, and documentation. Load only what is relevant to the review target.
3. Prioritize correctness, security, data loss, contract or specification violations, race conditions, and regressions. Report style only when required by repository rules or when it creates a concrete maintainability cost.
4. Validate every finding against the actual path or behavior. Trace callers and tests when needed; do not present speculative defects as facts.
5. Do not repeat formatter, compiler, typechecker, or linter output unless it affects the requested outcome or reveals a broader defect.
6. Recommend the smallest correct fix. Do not demand abstractions for hypothetical reuse.
7. Attach findings to a file and line when possible. State the impact, evidence, and smallest viable correction.
8. Order findings by severity. If there are no material findings, say so plainly and identify any verification gaps.

Severity:

- `Critical`: exploitable security issue, data loss, or fundamentally wrong behavior likely in normal use.
- `High`: definite correctness or contract failure with substantial impact.
- `Medium`: real edge-case failure, regression risk, or maintainability defect with a concrete cost.
- `Low`: worthwhile improvement that does not threaten correctness. Keep these sparse.

## Code Mode

### Establish the Review Target

Review the artifact or completed work Ivo identifies. For work just produced by an agent, inspect the actual changed files and the original request. Use Git history or diffs only when they help identify or understand those changes. If the target remains materially ambiguous, ask before reviewing.

### Review Two Independent Axes

Review both axes separately so a technically clean implementation cannot hide missing requirements, and apparent feature completion cannot hide unsafe or broken implementation.

**Requested Outcome**

- Compare the result with Ivo's original request and later clarifications.
- Identify missing, partial, incorrect, or contradictory behavior.
- Report unrequested behavior only when it changes the result or adds material risk or complexity.
- Cite the relevant requirement for each finding when possible.

**Implementation Integrity**

- Check correctness, security and data-loss risks, error handling, regressions, and applicable platform or repository constraints.
- Trace the actual behavior before reporting a defect. Treat maintainability concerns as findings only when they create a concrete present cost.
- Use the smallest relevant check allowed by the global testing and verification rules when it can confirm or disprove a suspected defect.

### Report

Present findings first, ordered by severity. Each finding should include a short title, the affected file or component, what breaks, the supporting evidence, and the smallest viable fix. Separate requested-outcome findings from implementation-integrity findings when both exist.

If there are no material findings, say so plainly. End with the checks performed and anything important that could not be verified.

## Independent Plan and Result Review

When independent review is requested or required by `AGENTS.md`, use the bundled read-only runner. It selects the opposite harness by default: Codex invokes Claude Code through the high-fidelity policy at Opus `medium` reasoning; Claude Code invokes Codex GPT-5.6 Sol at `medium` reasoning. Neither path retries — a reviewer failure surfaces as a failure. `PEER_REVIEWER=codex|claude` may override selection.

Before using active-context critique after any non-explicit automatic Claude review path fails at selection, launch, execution, or verdict validation, reuse the same hidden packet and invoke the runner exactly once with `PEER_REVIEWER=codex` to obtain a separate-context, read-only `codex exec` adversarial review. Treat either valid terminal recommendation (`PROCEED` or `REVISE`) as a completed review, disclose that Codex was used as fallback and that reviewer diversity was reduced, and do not invoke Codex twice when it was already selected. Only if the separate Codex invocation also fails may the active agent use an internal critique where `AGENTS.md` permits it, with both failed review routes disclosed. Never silently substitute a reviewer, and never override an explicitly requested reviewer.

Prepare one hidden review packet containing the actual artifact, Ivo's original request and clarifications, relevant constraints, and available verification evidence. Do not include the main agent's conclusions or suspected findings. Run the appropriate mode:

```bash
/Users/YOUR_USERNAME/.codex/skills/workflow\ skills/peer-review/scripts/run-peer-review.sh code|plan|result HIDDEN_PACKET [HIDDEN_LOG]
```

Plan mode assesses whether the approach will satisfy the request safely and efficiently. Result mode assesses the actual changes and verification evidence against the request. The reviewer ends with `RECOMMENDATION: PROCEED` or `RECOMMENDATION: REVISE` and supporting evidence.

The main agent verifies every finding and remains responsible for the final decision. Use one independent review round by default; review again only after material revisions or when the remaining risk justifies it.

Keep the reviewer read-only. It may inspect the supplied evidence but must not edit files, install dependencies, change external state, use MCP servers, or persist a session. Keep packets and optional logs in hidden/system working storage; do not create a user-visible file unless Ivo asks.

## Feedback Mode

Read all feedback and inspect the relevant artifact before deciding. Classify each item as supported, needs verification, unclear, or unsupported. Verify technical claims against the actual implementation and requirements.

If Ivo asked to implement the feedback, apply supported fixes in priority order: security and correctness, broken behavior, then cleanup. Validate the changed result. If he asked only for review, report the assessment without editing.

Reject feedback that contradicts requirements, breaks useful behavior, adds unrequested scope, conflicts with Ivo's decisions, or lacks evidence. Ask for clarification only when the ambiguity would materially change the outcome, following the global batched-clarification rule.

Report concise outcomes such as `Supported`, `Fixed`, `Rejected`, or `Needs clarification`, with evidence.
