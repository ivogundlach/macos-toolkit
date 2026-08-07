---
name: wayfinder
description: >-
  Use for explicit Wayfinder or decision-mapping requests, or when unresolved
  dependent decisions prevent reliable decomposition after calibration. Map the
  confirmed destination, not-yet-specified fog, decision tickets, blockers,
  frontier, links, and exit criteria before implementation; size alone is not a trigger.
---

# Wayfinder

Wayfinder is a decision-mapping workflow, not a build-plan or ticket-splitting
workflow. Enter it only for an explicit Wayfinder/decision-mapping request or when
unresolved dependent decisions block reliable decomposition after Grill calibration.
Effort size alone is insufficient.

Concept provenance: adapted from Matt Pocock's MIT-licensed Wayfinder, commit
`260225724133c4a204489599f04642aa089259a0`, dated 2026-07-13:
<https://github.com/mattpocock/skills/blob/260225724133c4a204489599f04642aa089259a0/skills/engineering/wayfinder/SKILL.md>.
This workflow is an original concise adaptation; do not copy upstream prose.

## State and entry

Use the shared monotonic state:

`uncalibrated -> calibrated -> mapped (only if needed) -> implementation-ready`

Grill normally supplies `calibrated`; Wayfinder owns `mapped` while its frontier is
open. Move to `implementation-ready` only when the destination, constraints, resolved
frontier, and execution authorization are all clear. Do not move backward unless Ivo
changes scope or new evidence invalidates a settled decision; record the cause and
affected ticket. Wayfinder may reuse `grill-with-memory` only for a newly surfaced HITL
decision, and may hand off to `vibe-coding` only at `implementation-ready` with
execution already authorized.

Before the destination is confirmed, keep sketches and candidate options in hidden task
scratch only. Do not write project or global memory for speculative work.
Confirm the destination with Ivo before persisting the map; a destination question is
HITL and must not be answered on his behalf. Do not stop after merely announcing
Wayfinder: if the destination is not confirmed, ask the bounded Grill question batch in
the same turn after context inspection.

## Map and ticket artifacts

Once Ivo confirms the destination, identify the nearest project folder. If it lacks
`.memory/`, initialize it with `project-memory-init` before writing map state. Use these
exact paths:

- Project effort: `<project>/.memory/wayfinding/<effort-slug>/map.md`
- Project tickets: `<project>/.memory/wayfinding/<effort-slug>/tickets/<NN>-<slug>.md`
- Project active pointer: `<project>/.memory/wayfinding/current.md`
- No project folder: `/Users/YOUR_USERNAME/.local/state/wayfinder/<effort-slug>/map.md`,
  `tickets/<NN>-<slug>.md`, and `current.md` in that effort directory.

The global fallback is hidden operational state; never put it in global `.memory/`.
External or GitHub trackers are opt-in and require explicit write authority.

Use this compact map schema:

~~~markdown
# Wayfinding Map: <effort-slug>
- Status: `active | blocked | complete`
- State: `mapped | implementation-ready`
- Destination: <one confirmed user-visible outcome>
- Not-yet-specified fog:
  - <material unknown or dependency>
- Out of scope:
  - <explicit non-goal>
- Blockers:
  - <blocker, owner, or `none`>
- Frontier: `T01`, `T02`
- Links and pointers:
  - <name>: <path or URL> — <why it matters>
- Resolution criteria:
  - <what must be decided or evidenced>
- Exit criteria:
  - <conditions for implementation-ready>
- Updated: <YYYY-MM-DD>
~~~

Use this compact decision-ticket schema. Decision tickets are questions, not build slices or task checklists:

~~~markdown
# Decision Ticket T<NN>: <slug>
- Status: `open | claimed | resolved | blocked | dropped`
- Question: <one decision question>
- Why it matters: <downstream behavior, scope, risk, or dependency>
- Options and tradeoffs:
  - <option>: <tradeoff>
- Recommended default: <option and reason, or `none`>
- Owner: `Ivo | agent | <named owner>`
- Evidence and links:
  - <named pointer>
- Resolution: <confirmed answer, evidence, or `unresolved`>
- Exit criterion: <observable condition for resolving this ticket>
- History: <append-only status, owner, and resolution entries>
- Updated: <YYYY-MM-DD>
~~~

The active `current.md` pointer uses this compact schema:

~~~markdown
# Active Wayfinding
- Effort: <effort-slug>
- Map: <relative path to map.md>
- State: `mapped | implementation-ready`
- Updated: <YYYY-MM-DD>
~~~

Create one ticket per material decision, not one ticket per task. Keep the map's
`Destination`, `Not-yet-specified fog`, `Out of scope`, `Blockers`, `Frontier`, named
links/pointers, resolution criteria, and exit criteria current as tickets change.

## Frontier protocol

- **Claim:** select a frontier ticket, set `Status: claimed`, name the owner, and add
  the date. Do not claim a ticket already claimed by another owner.
- **Update:** append the relevant evidence, options, named links, dependency, or blocker;
  preserve the question and prior resolution history rather than silently rewriting it.
- **Resolve:** set `Status: resolved`, record the confirmed answer/evidence and exit
  criterion, then refresh the map frontier and dependent tickets. A HITL ticket is
  resolved only by Ivo's answer; never answer his side.
- **Block:** set `Status: blocked`, name the blocker/owner, and remove it from the
  actionable frontier until every blocker clears.
- **Drop:** set `Status: dropped` only when scope removes the question, recording why.

Resolve frontier tickets sequentially by default. Parallelize only independent AFK
research when the current subagent policy indicates it is likely to save total effort;
do not create automatic research branches or unconditionally fan out subagents.

## Completion and memory

The map is complete only when every frontier ticket is `resolved` or deliberately
`dropped` with rationale, blockers are clear, resolution and exit criteria pass, the
destination and out-of-scope boundaries are confirmed, and execution is authorized.
Set the map `Status: complete` and `State: implementation-ready`, record the completion
date, retain the map and tickets as project history, and remove the active `current.md`
pointer. Leave the pointer in place for `active` or `blocked` work.

Capture only confirmed decisions and constraints through `auto-remember` after
resolution. Speculative, open, blocked, or abandoned tickets are operational state, not
ledger or wiki facts. Do not pollute global memory when using the no-project fallback.
