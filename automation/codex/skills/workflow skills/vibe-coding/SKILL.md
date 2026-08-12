---
name: vibe-coding
description: >-
  Use on every coding task: creating, modifying, refactoring, debugging,
  fixing, reviewing, testing, scripting, building, integrating, simplifying,
  or optimizing code, apps, sites, services, CLIs, games, automations, and
  technical workflows, including SwiftUI, SwiftData, macOS apps, Xcode,
  Command Line Tools, `swiftc`, app bundles, codesigning, and Launchie. Also
  trigger when Ivo says vibe coding, ponytail, lazy
  mode, YAGNI, simplest solution, minimal solution, do less, or complains
  about over-engineering, bloat, boilerplate, unnecessary dependencies, or too
  much code. This is Ivo's default hands-off coding workflow: independently
  inspect the project, make the smallest maintainable change, diagnose causes
  before fixing symptoms, measure performance claims, verify proportionally,
  and deliver the working outcome. Combine with a narrower platform or tool
  skill when applicable; for review-only work also use peer-review. Skip only
  when no code, configuration, script, build, or technical artifact is involved.
---

# Vibe Coding

Turn Ivo's requested outcome into a working result without requiring him to manage the implementation. Operate autonomously inside the approved scope and follow the execution, clarification, and verification rules in `AGENTS.md`.

## Discovery handoff

Honor the shared monotonic state: `uncalibrated -> calibrated -> mapped (only if needed) -> implementation-ready`.
When `grill-with-memory` has completed calibration, start from `calibrated` and do not restart Grill. Implement calibrated ordinary work directly. If unresolved dependent
decisions prevent reliable decomposition, use `wayfinder`; accept its handoff only at
`implementation-ready` and when execution is already authorized. Deterministic or
settled work remains eligible for direct implementation without discovery.

For SwiftUI macOS building, packaging, signing, installation, or app-identity work, read [references/swiftui-macos.md](references/swiftui-macos.md) before changing or building the project.
For any macOS app build, packaging, installation, runtime smoke test, or visual verification—whether SwiftUI, AppKit, Catalyst, Electron, or another app technology—read [references/swiftui-macos.md](references/swiftui-macos.md) before acting; its app-identity and single-instance gates apply across technologies.

## Core Approach

Name the target end state before writing any code: what must be true when this works, how Ivo will judge it, and what is out of scope. Infer it from the project first, then state it in one or two plain-English lines. When two plausible end states would produce materially different results, resolve that before implementing — a fast one-shot at the wrong goal is still the wrong deliverable. A request phrased as a mechanism ("add a button", "change the query") is still a request for an outcome; build against the outcome.

1. Inspect the relevant project state, current behavior, conventions, documentation, and existing user changes.
2. Choose the smallest maintainable solution. Prefer removing unnecessary work, native or standard-library features, and already-installed dependencies before writing custom code.
3. Do not preserve legacy behavior or compatibility unless the current requirements, an explicit public contract, stored data, or an active integration requires it.
4. When functionality is nontrivial and a dependency is justified, prefer an established, well-maintained library over a custom implementation.
5. Implement the complete requested outcome. Avoid speculative scaffolding, unnecessary files, premature abstractions, and dependencies without a clear present benefit.
6. Preserve requested behavior, public contracts, data integrity, trust-boundary validation, security, accessibility, and useful project conventions. Do not optimize for line count.
7. Verify the actual result with the smallest relevant check and inspect for collateral changes before reporting completion.

## Deployed Copies

Many of Ivo's projects run from a copy rather than from the repo: app bundles in `/Applications`, wrappers in `~/.local/bin`, LaunchAgent plists in `~/Library/LaunchAgents`, installed extensions. Before editing a file, determine whether the running copy is the one being edited. Treat the repo as the source of truth, edit there, then run the project's build or install step so the deployed copy matches; never hand-edit a deployed copy, and never leave a repo edit undeployed. A repo edit without the deploy step silently keeps old code running, which then reports stale behavior that looks like a real fault. Verify against the deployed copy, not the source. Archive or mirror trees are written only by their sync script.

## Editing Existing Source

Prefer anchored edits that match the exact text being replaced. When a change is large enough to want a script, **compute the span and print what it covers before deleting it** — a start anchor and an end anchor that resolve in the wrong order silently delete everything between them, and a file that still compiles is not proof, because the loss can be a property the compiler only misses later. After any structural edit, diff or re-read the touched region rather than trusting that the build passed.

Before the first structural edit in a project, check whether it is under version control. If it is not, say so and offer to initialise it; an unversioned project turns an editing mistake into a recovery problem.

## Work Modes

### Build, Change, or Refactor

Keep the change contained but fully integrated. Prefer boring, readable code over clever compression. Add comments only when the behavior itself would otherwise be unclear.

### Diagnose or Fix

For diagnosis-only requests, identify and explain the cause without editing. When a fix is requested, gather evidence or reproduce the fault when practical, trace the first incorrect layer, test one plausible cause at a time, and fix the cause rather than masking the symptom. After repeated unsupported attempts, reassess the model instead of stacking guesses.

### Optimize

Define the affected surface, meaningful metric, and measurement conditions. Capture a repeatable baseline, locate a measured bottleneck, make one focused change, and repeat the same measurement. Claim improvement only from repeatable raw before-and-after results with affected behavior preserved. Revert only the agent's own failed attempt; never discard pre-existing user work.

### Review

Keep review-only work read-only unless Ivo also asks for changes. Use `peer-review` for the review method and evidence standard.

## Finish

Continue until the requested outcome works or a genuine blocker requires Ivo. Do not stop at a plausible patch. After a verified code, configuration, or script change, invoke `github-workflow` when the current request or canonical repository/project memory already records commit, push, or archive authority for that destination; never infer authority for another repository. Lead the final response with the result, then state the material change, validation performed, versioning outcome, and anything still unverified or blocked.
