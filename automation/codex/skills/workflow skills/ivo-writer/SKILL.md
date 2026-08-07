---
name: ivo-writer
description: >-
  Use when writing or drafting any text another human will read, including emails,
  replies, messages, personal drafts and notes, essays, applications, formal
  documents, letters, and posts. Skip for internal chat answers, code, system
  files, repository documentation, and AGENTS or skill edits.
---

# Ivo writer

Write exceptionally strong prose in Ivo's direct, assertive voice. Preserve meaning, factual integrity, real personality, and the reader's practical needs. This skill is a writing-quality system.

## Target-language gate

Before any human-facing draft, declare and verify the target language. Ivo's instruction language is not the target language unless he explicitly names the draft language. For correspondence, read and apply [references/correspondence.md](references/correspondence.md), including its mandatory target-language gate.

## Select the mode

1. For email, replies, and messages, read [references/correspondence.md](references/correspondence.md).
2. For personal drafts and notes, school-related material, applications, posts, essays, and formal documents, read [references/formal.md](references/formal.md).
3. In either mode, read and apply [references/style-controls.md](references/style-controls.md).

For school or formal work, establish the use branch before drafting. Graded, assessed, submission-intended, or unclear work always uses `assessed_or_unknown`, regardless of any authorship claim. High-quality personal drafts and notes may use `personal_generation` when Ivo affirmatively says they are non-assessed. Detector-pattern review is allowed only for `user_authored_personal`: Ivo must separately confirm that he wrote the supplied prose and that it is non-assessed personal text.

## Preserve truth and voice

- Preserve every material fact, ask, constraint, deadline, identifier, and source claim.
- Use private or unrecorded experiences only when Ivo supplied them. Never invent personal history or specificity.
- State defensible opinions directly. Keep objective facts, uncertainty, quotations, and source status accurate.
- Prefer the shortest complete draft, not the shortest possible draft.
- Do not flatten useful irregularity, mixed feelings, or first-person judgment into generic polish.

## Draft and audit

1. Identify the audience, intended use, and correct mode or branch.
2. Draft for logic, intent, completeness, and Ivo's cadence.
3. Apply the relevant reference rules.
4. Check factual and internal consistency. Remove placeholders, unfinished markers, assistant residue, duplicated blocks, and broken markup.
5. Run the local checker when a draft is substantial enough to benefit from a mechanical pass.
6. Fix ordinary errors. Treat detector-related `style_cluster` findings as report-only; never silently rewrite solely to clear them.
7. Output the final prose directly unless Ivo asked for analysis or a saved deliverable.

## Local checker

The checker is deterministic, local, privacy-preserving by default, and never rewrites text. It reports mechanical violations and returns structured JSON.

```bash
python3 "$SKILL_DIR/scripts/check-draft.py" --mode correspondence < draft.txt
python3 "$SKILL_DIR/scripts/check-draft.py" --mode document < draft.txt
python3 "$SKILL_DIR/scripts/check-draft.py" --mode document --assert-authorship --assert-non-assessed < draft.txt
```

Use both assertion flags only when Ivo separately confirmed both facts required by `user_authored_personal`. Never infer them. Correspondence mode rejects the flags. Do not use detector analysis for assessed, submission-intended, or ambiguous work.

Exit codes:

- `0`: pass
- `1`: needs review because one or more error or warning findings were emitted; a report-only warning does not authorize rewriting
- `2`: invocation or input error
- `3`: internal checker error

Default output does not echo source text. `--show-snippets` is explicit opt-in and should be used only when exposing snippets is appropriate for the current context.

## Compatibility boundary

The unattended Apple Mail draft runner currently contains a trusted copy of the correspondence rules. This skill must preserve those behaviors, but changing or deduplicating that runtime is outside this skill's scope and requires a separate reviewed migration.
