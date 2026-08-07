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

## Portable Luna implementation lane

Route every planned agent-authored coding edit through this portable lane, including
source, configuration, scripts, tests, build mechanics, technical instructions, rules,
skills, and other technical artifacts. Keep the user conversation, material ambiguity,
architecture and interfaces, required independent plan-review feedback, verification,
critique, and acceptance in the primary process. Preserve existing importance-based
independent plan-review triggers; this lane does not add a routine result reviewer.

### Contract

Before delegation, capture enough state to attribute the worker's changes. In a Git
working tree, inspect `git status --short --untracked-files=all`, record content
baselines for every owned file, and declare generated paths and mutating verification
commands. In an unversioned tree, record the relevant path set and owned-file content
baselines; inventory each relevant owned parent with path, type, mode, symlink target,
and content hash where applicable. Include deployed or external paths when the task can
affect them. Do not delegate when concurrent changes make safe attribution impossible.

Give every implementation path exactly this contract template; do not create native,
bridge, or direct variants:

~~~text
OBJECTIVE
<Observable outcome and why it matters.>

FILES AND OWNERSHIP
You own only:
- <exact file, directory, or declared generated path>

You are not alone in the codebase. Preserve concurrent and unrelated edits, do not
revert work you did not author, and do not modify paths outside this ownership.

INTERFACES
- <Signatures, formats, commands, behavior, or compatibility to preserve.>

CONSTRAINTS
- <Settled architecture, repository rules, safety boundaries, and excluded scope.>

For every Luna dispatch, the primary selects reasoning by task judgment: start at
high; choose xhigh for one established material multiplier (cross-subsystem
interface, concurrency/state transition, difficult rollback/recovery, or several
coupled correctness constraints); choose max for two or more multipliers or one
exceptional consequence (destructive migration, authentication/permission boundary,
shared recovery, or governing control-plane policy) where xhigh is reasonably
insufficient. Max may be chosen initially when exceptional facts are established.
Mere file count, unfamiliarity, or length do not raise effort; when uncertain choose
high. Long-run guidance is aspirational, non-random, and non-quota (high 50%, xhigh
35%, max 15%); task judgment controls each dispatch. Add exactly
`Selected Luna reasoning: <level> - <one-clause rationale>` to CONSTRAINTS, and
require the worker to echo that line in JUDGMENT CALLS.

VERIFICATION
- Run: <exact command>
  Success: <concrete expected result>
- Inspect: <exact file, diff, or artifact>
  Success: <concrete expected evidence>

RETURN
Return exact commands and actual evidence in exactly this report structure:

STATUS: complete | partial | blocked
OBJECTIVE: <one-line restatement>
CHANGES: <file-by-file summary of actual changes>
VERIFIED: <exact commands and concrete result evidence>
JUDGMENT CALLS: <decisions the specification left open, or none>
GAPS: <unfinished work, ambiguity, failed checks, or none>

Choose exactly one allowed STATUS value. A completion claim without evidence is invalid.
~~~

### Dispatch

0. If `IVO_LUNA_IMPLEMENTER=1` is set, treat this process as the already-designated
   Luna worker. Implement the supplied contract directly; never spawn another agent or
   invoke `luna-implement`; return the six required headings with actual evidence.
1. When this harness exposes the exact native sibling roles, spawn the role matching
   the selected reasoning level — `luna_implementer` (high/default),
   `luna_implementer_xhigh` (xhigh), or `luna_implementer_max` (max) — with
   `fork_turns: none` and no per-spawn model or reasoning overrides. Each role pins
   GPT-5.6 Luna and its named effort. If the selected native role is unavailable or
   spawning fails before worker execution, continue to step 2; if execution may have
   begun, inspect all partial state before continuing and do not classify the failure
   as bridge unavailability.
2. When the selected native role is unavailable, or fails positively before worker
   execution,
   perform one existence check for
   `/Users/YOUR_USERNAME/.local/bin/luna-implement`, then one side-effect-free
   `/Users/YOUR_USERNAME/.local/bin/luna-implement --version` capability check. If both
   pass, invoke the wrapper with the same contract on stdin and the narrowest feasible
   roots:

   `luna-implement --reasoning <selected> [--cd DIR] [--add-dir DIR ...] [--sandbox read-only|workspace-write|danger-full-access]`

   The wrapper defaults to `workspace-write` and high reasoning, uses a fresh headless
   GPT-5.6 Luna process, and keeps the contract only on stdin. Never put secrets in the
   contract; Codex diagnostics may display submitted instructions. It must reject nested
   `IVO_LUNA_IMPLEMENTER=1`, validate candidates and directories before execution, set
   that marker for the worker, and stream Codex stdin/stdout/stderr directly. Codex
   diagnostics stay on stderr; terminal stdout must be one six-heading worker report.
   Resolve and pass each path as a separate argument. Treat races in resolved parent
   components as a documented residual limitation; do not claim impossible race
   elimination.
3. If no bridge can launch because of a positively identified pre-launch,
   capability, authentication, or transport failure, implement directly in the primary
   under the identical contract, baselines, ownership/diff inspection, verification,
   and six-heading report. Disclose exactly:

   `Implementation fallback: Luna bridge unavailable (<brief cause>); this harness implemented directly under the same contract.`

   Do not ask Ivo solely because the adapter is absent. Stop instead when Ivo explicitly
   requires Luna, direct work is unsafe, or attribution is unclear. Do not treat invalid
   contracts, test failures, safety stops, worker rejection, malformed or missing
   reports, task failures, or any failure after worker execution may have begun as bridge
   unavailability. Inspect every writable root and partial state first; continue only
   when observed state makes attribution and safety clear. After any interruption,
   inspect the same partial state before retrying or changing paths; never blindly rerun.

Treat the worker report as a claim. Inspect the complete actual change set across every
writable root (sandbox roots are not exact-file ownership enforcement), reject or escalate
changes outside declared ownership, rerun verification in the primary session, and
critique the implementation against the objective, interfaces, constraints, and
acceptance criteria. Choose the narrowest feasible sandbox roots and baseline all
declared owned/generated paths plus complete Git status/diff where applicable. The
primary may directly make only the existing mechanically evident, small,
acceptance-preserving bounded repair confined to accepted files and requiring no new
interface, dependency, architecture, scope, product judgment, or acceptance decision;
substantial remaining implementation returns through this lane. Deterministic formatter,
generator, installer, validator, and canonical-sync output does not require another
delegation, but agent-authored changes to those mechanics do.

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
