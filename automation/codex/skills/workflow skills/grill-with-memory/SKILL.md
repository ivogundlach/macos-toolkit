---
name: grill-with-memory
description: >-
  Use for greenfield apps, sites, automations, tools, products, documents, designs,
  or plans; substantial new features or redesigns; and creation/change requests with
  at least two plausible interpretations that materially change user-visible behavior,
  scope, data, platform, integration, privacy, or effort. May trigger for smaller
  preference-sensitive work. Skip factual Q&A, read-only inspection, summary, or
  review; exact bounded edits; diagnosis with settled desired behavior; settled
  continuations; deterministic workflows that answer all product choices; or an
  explicit request to skip product discovery. Skipping discovery never waives
  authority, safety, destructive-action, or blocker clarification.
---

# Grill With Memory

<core-instructions>

Use a short, structured calibration before implementation when the activation matrix
requires it. Inspect context first, ask only material questions, and preserve a clear
handoff to the next workflow. Do not add routine discovery friction to settled work.
Do not end a turn with only a skill announcement, discovery plan, or promise to ask
later. After context inspection, present the required question batch in that same turn
unless a mandatory tool result or user-only prerequisite genuinely blocks it.

State the intended end state alongside the question batch, in one or two plain-English
lines: what the finished thing does, how Ivo will judge it, and what it excludes. Ivo
must be able to correct the goal, not only answer the questions.

</core-instructions>

## Activation matrix

- **MUST trigger:** greenfield apps, sites, automations, tools, products, documents,
  designs, or plans; substantial new features or redesigns; or a creation/change
  request with at least two plausible interpretations that materially alter behavior,
  scope, data, platform, integration, privacy, or effort.
- **MAY trigger:** smaller work whose outcome is preference-sensitive and not settled by
  the request or available context.
- **MUST NOT trigger:** factual Q&A; read-only inspection, summary, or review; exact
  bounded edits; diagnosis with a settled desired behavior; settled continuations; a
  deterministic workflow that demonstrably answers every product choice; or an explicit
  request to skip product discovery.

An explicit skip suppresses product questions only. It never suppresses authority,
safety, destructive-action, privacy, or blocker clarification when those are required.

## Preparation and specialist precedence

1. Inspect the relevant files, nearest project memory, targeted global memory,
   connectors, and task context before asking Ivo.
2. Apply a specialist skill before questioning where it is active. A specialist may
   skip only the questions it demonstrably answers; it does not waive unresolved choices
   outside its contract.
3. Build a private decision map containing intended outcome, audience, constraints,
   success criteria, tradeoffs, failure modes, non-goals, and unresolved dependencies.

## Calibration modes

Use the light mode by default for a new app, product, or ordinary greenfield request:

- Ask exactly 2 or 3 high-leverage questions in one structured batch. Never exceed
  3 questions or append extra free-form questions outside that batch.
- Put the recommended default first and state its main tradeoff in each question.
- Ask a second adaptive batch only if Ivo's answers expose a genuinely new material
  branch, blocker, dependency, or consequential misunderstanding.

Use full discovery when choices are materially interdependent—one answer changes which
later questions, constraints, or failure modes matter. Ask the currently necessary
questions in upstream-to-downstream order, not a fixed questionnaire. If Ivo cannot
answer a low-impact item, record an explicit assumption or open flag and proceed.

After each batch, reassess the decision map. Do not reopen settled questions unless Ivo
changes scope or new evidence invalidates a settled decision.

## Monotonic routing

Track the shared state explicitly:

`uncalibrated -> calibrated -> mapped (only if needed) -> implementation-ready`

- Finish calibration at **calibrated** when intended behavior, constraints, success
  criteria, and non-goals are sufficient for reliable implementation.
- Route calibrated ordinary work directly to `vibe-coding`.
- Route to `wayfinder` only when dependent decisions remain unresolved and prevent
  reliable decomposition; size alone is not a reason.
- `vibe-coding` must not restart Grill when calibration is complete.
- Wayfinder may reuse Grill only for a newly surfaced HITL decision, and may hand off
  to `vibe-coding` only at `implementation-ready` when execution is already authorized.
- Do not move backward unless Ivo changes scope or new evidence invalidates a settled
  decision; record that cause and the affected state.

## Discovery handoff and memory

After discovery, provide a concise synthesis of the intended outcome, decisions and
tradeoffs, constraints, success criteria, non-goals, assumptions, and unresolved flags.
When the task includes execution, continue under its authorization and routing state.
After discovery is complete, use `auto-remember` once for confirmed durable decisions,
constraints, preferences, workflows, or sources. Do not capture speculative or abandoned
options as durable memory; Wayfinder operational state has its own persistence rules.
