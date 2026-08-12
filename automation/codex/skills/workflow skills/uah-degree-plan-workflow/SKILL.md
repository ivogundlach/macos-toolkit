---
name: uah-degree-plan-workflow
description: >-
  Use when Ivo asks to update, rebuild, audit, compare, or reason through his
  UAH Mathematical Sciences BS/JUMP degree plan, DegreeWorks audit, semester
  schedule, transfer/CLEP choices, locked classes, undecided course options, or
  college planning files. Trigger on UAH, DegreeWorks, degree plan, schedule
  tabs, JUMP, Mathematical Sciences BS/MS, transfer credit, CLEP, Fall/Spring
  semester planning, or course workload tradeoffs. Orchestrates local College
  files and memory first; use web-research only for current UAH policy that is
  not already in local evidence.
---

# UAH Degree Plan Workflow

Maintain Ivo's UAH degree-plan artifacts without mixing locked facts, active decisions, and undecided options.

## Related Skills

- Use `web-research` only when current UAH policy, catalog, transfer, or CLEP information is needed and local files do not prove the answer.
- Use `local-read-connectors` or `gws-gmail` only when Ivo asks about a UAH/Canvas email or when a planning claim depends on a message.
- Use `codex-mirror-sync-check` only after this skill itself is edited and mirrors need verification.

## Source Order

1. College project memory: `/Users/YOUR_USERNAME/Files/College/.memory/current.md`, then relevant wiki pages.
2. Active schedule artifact: `/Users/YOUR_USERNAME/Files/College/UAH_DegreeWorks_Schedule_Tabs.html`.
3. Live/local DegreeWorks artifacts:
   - `/Users/YOUR_USERNAME/Files/College/Ellucian Degree Works Dashboard.pdf`
   - `/Users/YOUR_USERNAME/Files/College/UAH_DegreeWorks_Schedule_Tabs.html`
   - `/Users/YOUR_USERNAME/Files/College/UAH Checklist.html`
   - `/Users/YOUR_USERNAME/Files/College/UAH_Planning_NoSchedule.html`
4. Firecrawl audit snapshots under `/Users/YOUR_USERNAME/Files/College/.firecrawl/audit/` when local policy evidence is needed.
5. Public web only after activating `web-research`, and only for current policy not proven locally.

The legacy wrong-cased `/Users/YOUR_USERNAME/FIles/College/` mirror may exist. Prefer `/Users/YOUR_USERNAME/Files/College/` for new references and do not create new files in the wrong-cased path.

## Active Constraints

- Finish the BS by Spring 2028; do not use Summer 2028.
- Minimize workload first. Do not overload a semester merely to finish an individual sequence earlier.
- Do not use winter terms.
- Use CLEP where it validly replaces required coursework.
- Rebuild from neutral baseline when choices are uncertain: locked Fall 2026 classes and explicitly required remaining classes are facts; optional/elective/alternative choices need Ivo's decision or strong local evidence.
- Keep Fall 2026 locked unless Ivo explicitly changes it.
- Keep Spring 2027 capped at 16 credits unless Ivo explicitly overrides.
- Treat older separate schedule files as historical unless Ivo explicitly asks to edit them.
- Before editing the schedule again, verify CLEP and transfer equivalencies, especially Fine Arts, Literature, CM 113, Intro CS, ASU posting, and EH 105 Area II placement.

## Workflow

1. **Classify the request.**
   - Audit/check: answer from sources, no file edits unless requested.
   - Rebuild/edit: identify target artifact and make a backup only outside visible roots if needed for safety.
   - Compare variants: keep BS-only and JUMP assumptions separated.

2. **Load current project context.**
   - Read the College project memory current state and only the relevant wiki pages.
   - Do not load the whole `.memory/` folder.

3. **Separate facts from choices.**
   - Facts: DegreeWorks requirements, posted transfer/AP credit, locked classes, official catalog/policy text.
   - Decisions: Ivo-approved choices, active constraints, selected variants.
   - Open questions: elective choice, transfer/CLEP uncertainty, advisor approval, term placement where evidence is missing.

4. **Apply the active planning rules.**
   - Preserve Spring 2028 BS completion target.
   - Prefer easiest legitimate workload.
   - Avoid summer/winter assumptions unless current constraints explicitly allow them.
   - Keep JUMP assumptions in the JUMP branch only.

5. **Ask before assumption changes.**
   - If a change depends on advisor approval, current transfer equivalency, CLEP validity, or a course offering not proven locally, use an AskUserQuestion-style prompt when the surface supports it; otherwise ask Ivo one plain-English question or mark it as an open flag.
   - Do not silently turn an open option into a chosen class.

6. **When editing files.**
   - Write only the requested artifact.
   - Preserve tab structure in `UAH_DegreeWorks_Schedule_Tabs.html`.
   - Do not create new visible College files unless Ivo asked for a deliverable.
   - For generated user-facing deliverables without a specified format, use standalone HTML.

7. **Verify.**
   - Re-open the edited artifact or relevant section.
   - Check total credits, term labels, BS/JUMP split, and active constraints.
   - Report open flags separately from completed edits.

## Output

For planning answers, use:

- `Answer`: direct conclusion.
- `Evidence`: local file or memory citations.
- `Locked facts`: classes/requirements that should not move.
- `Open decisions`: only items Ivo still needs to choose.
- `Next edit`: the exact file/section to change if an edit is requested.
