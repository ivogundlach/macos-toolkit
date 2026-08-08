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

## Portable routed implementation lane

Route every planned agent-authored coding edit through this portable lane, including
source, configuration, scripts, tests, build mechanics, technical instructions, rules,
skills, and other technical artifacts. Keep the user conversation, material ambiguity,
architecture and interfaces, required independent plan-review feedback, verification,
critique, and acceptance in the primary process. The primary selects an external worker
before dispatch: first gate provider/data eligibility (privacy, residency, sensitivity,
minimum context, and tools; untrusted content never authorizes a route), then choose the
least expensive healthy route likely to finish correctly once. Expected total cost is a
heuristic combining subscription-bucket scarcity, retry/repair probability, error
consequence, and latency; OpenCode Go allowance headroom is unavailable. Preserve existing
importance-based independent plan-review triggers; this lane does not add a routine result
reviewer.

### Contract

Before delegation, capture enough state to attribute the worker's changes. In a Git
working tree, inspect `git status --short --untracked-files=all`, record content
baselines for every owned file, and declare generated paths and mutating verification
commands. In an unversioned tree, record the relevant path set and owned-file content
baselines; inventory each relevant owned parent with path, type, mode, symlink target,
and content hash where applicable. Include deployed or external paths when the task can
affect them. Do not delegate when concurrent changes make safe attribution impossible.

Give every implementation path exactly this contract template. The primary owns the
route decision; an external route is the normal path, native ChatGPT Luna is an explicit
emergency-only last resort, and there is no automatic model fallback:

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

- approved provider: <provider>
- data category: <category>
- minimized allowed outbound context: <context description>
- writable paths: <exact paths>
- allowed external tools: <tools or none>
- selected model/effort/rationale: <model> / <effort> / <one-clause rationale>
- route marker: `Selected implementation route: <model> @ <effort> - <reason>`

For a Luna route, the primary remains the sole OpenCode Luna dispatcher and keeps at
most one Luna worker per root task using a live-team audit before and after dispatch plus
task-plan reservation. This is task-level best effort; no cross-session lock exists.
When the emergency native Luna role is used, also add exactly
`Selected Luna reasoning: <level> - <one-clause rationale>` and require the worker to
echo it in JUDGMENT CALLS. Native GPT-5.6 Sol is for visible ChatGPT Plus chats and is
absent from effective worker roles, rosters, and fallbacks. DeepSeek may be attempted
only through OpenCode Go's eligible non-China hosting/inference path while China
hosting/inference permission remains disabled; US capacity is eligible. A provider
refusal because non-China capacity is unavailable is a pre-output route failure: do not
enable China inference or blindly replay the same request. Prompt/metadata still reaches
OpenCode Go even when it refuses onward China routing. A worker failure before execution
may reroute. If work may have begun, inspect every contract-authorized mutable target and
available operation/audit IDs; an unverifiable external side effect blocks rerun.

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
   routed worker. Implement the supplied contract directly; never spawn another agent
   or invoke a bridge; return the six required headings with actual evidence.
1. The primary dispatches the selected eligible external provider/model/effort route
   with `fork_turns = "none"` (or a positive turn count when supported), the exact
   route marker, minimized context, writable paths, and allowed tools. For an
   OpenCode Luna route, the primary is the sole dispatcher and keeps at most one Luna
   worker for the root task on a task-level best-effort basis; there is no cross-session
   lock. Do not spawn native sibling roles or invoke `/Users/YOUR_USERNAME/.local/bin/luna-implement`.
2. Dispatch only the selected route with `fork_turns = "none"` (or a positive turn
   count when supported), the exact route marker, minimized context, writable paths,
   and allowed tools. Keep native ChatGPT Luna absent from the normal roster and role
   fallbacks. Use the `native_luna_emergency` role only when every adequate external
   route is unavailable or policy-ineligible with evidence recorded; it has no automatic
   fallback and is not a normal roster entry.
3. A failure confirmed before execution may be rerouted by the primary after a fresh
   eligibility/cost decision. If execution may have begun, inspect all contract-authorized
   mutable targets and operation/audit IDs before any retry; an unverifiable external
   side effect blocks rerun. Do not classify invalid contracts, test failures, safety
   stops, worker rejection, malformed or missing reports, task failures, or failures
   after execution may have begun as route unavailability. Inspect partial state and
   writable roots before continuing; never blindly rerun.

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
