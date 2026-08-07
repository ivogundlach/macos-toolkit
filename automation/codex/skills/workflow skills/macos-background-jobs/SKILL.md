---
name: macos-background-jobs
description: >-
  Use when Ivo asks to create, schedule, repair, audit, or troubleshoot a
  recurring local macOS job; choose cron versus LaunchAgent; fix work that
  succeeds interactively but fails in the background; handle missed runs,
  retries, permissions, authentication, duplicate schedulers, silent failures,
  noisy Background Items notices, or an app that must keep working after its
  window closes. Covers local Mac plumbing only. Skip cloud/Codex automations,
  hotkeys, and one-off scripts.
---

# macOS Background Jobs

<core-instructions>

Build local jobs that remain correct after reboot, sleep, offline periods, auth
expiry, application closure, and later agent edits. Treat the scheduler context
as production. A successful interactive run is necessary but never sufficient.

</core-instructions>

<mechanism-selection>

## Choose the Mechanism

| Situation | Mechanism |
|---|---|
| Fixed recurring non-GUI script; cron and launchd both satisfy the contract | cron, to avoid per-agent Background Items noise |
| Needs `RunAtLoad`, `KeepAlive`, `WatchPaths`, GUI-session access, TCC permissions, or launchd wake/coalescing behavior | LaunchAgent |
| Known future timestamp | Target that event directly |
| Future timestamps change dynamically and background schedule mutation is unavailable | One static cheap poller reading a state file |
| Worker must survive closing a visible app | Separate worker/helper; do not keep a Dock app open and call it background work |
| Keystroke trigger | skhd; not this skill |
| Cloud-side agent routine | Use the platform automation path; not this skill |

Prefer event-targeted scheduling when the timestamp is known. Use polling only
when discovery is genuinely required or the platform prevents dynamic schedule
updates. Keep a poller local and cheap; perform network or model work only in the
actual execution window.

</mechanism-selection>

<workflow>

## 1. Inventory Before Changing Anything

Inspect the live system before designing or repairing a job:

- Read `crontab -l`, relevant files in `~/Library/LaunchAgents/`, and
  `launchctl print gui/$(id -u)`.
- Find existing wrappers, state, logs, running processes, helper apps, and Tool
  Status Dashboard producers for the same logical task.
- Identify the owner, current cadence, execution contract, and retirement path.
- Preserve the cadence while fixing an unrelated failure. Never silently change
  hourly, daily, alternating-day, or weekly behavior.
- Treat third-party, manual-trigger, and on-demand jobs as potentially
  externally owned until provenance proves otherwise. Trigger mode does not
  establish ownership.
- Treat an empty plist dictionary as non-runnable. It may be a migration
  tombstone, placeholder, unfinished file, or corruption; inspect its owner and
  history instead of inferring a label from the filename or bootstrapping it.
- Identify every interactive dependency. An unattended path must never require
  a Terminal prompt, browser OAuth, Finder dialog, or click action.

Do not create a second scheduler, notifier, helper app, or wrapper when an
existing component owns the task.

## 2. Build One Explicit Job Contract

- Use one scheduler entry per logical job. Share a wrapper between modes only
  when the modes belong to that same job; never bundle unrelated scripts.
- Put reusable wrappers in `~/.local/bin/`. Use absolute executable paths, an
  explicit minimal `PATH`, an explicit working directory when required, and no
  shell aliases or login-shell assumptions.
- Put state and ordinary logs in `~/.local/state/<job>/`. Memory infrastructure
  may use `~/.memory/logs/<job>/`. Never write backend state to `~/Files`.
- Make installation idempotent. Address cron entries by a unique managed
  comment and LaunchAgents by their exact label. Preserve unrelated entries.
- Use a lock to prevent overlapping work. An overlap skip is not evidence that
  the underlying job is healthy.
- Resolve and record the executable actually used by the scheduler. For bundled
  or frequently updated CLIs, verify the scheduled path and version rather than
  trusting an old `~/.local/bin` copy.

Machine-specific constraint: background cron and LaunchAgent processes on this
Mac cannot replace the user crontab, even when the same command works
interactively. Never build self-modifying cron. Install static entries from the
interactive session and store dynamic targets in an ordinary state file.

## 3. Model Success, Deferral, Failure, and Recovery Separately

| State | Required behavior |
|---|---|
| Success | Update last-success state, clear completed pending work, remain silent |
| Expected idle or overlap | Record if useful; do not treat as success or failure |
| Offline/transient defer | Preserve pending work, do not advance success markers, retry quietly |
| Confirmed auth required | Stop repeated background attempts, preserve work, report one actionable incident; never open OAuth from the background |
| Real failure | Preserve evidence, return failure, report one deduplicated actionable incident |
| Recovery | Clear the active incident under the dashboard recovery policy so a later recurrence can alert again |

Keep last-attempt and last-success distinct. Trust final exit status and output
artifacts over transient stderr. Never mark a time window complete merely
because work was deferred. Carry missed work forward when the job contract
requires catch-up.

Judge health from the job's real contract: output artifact, state transition,
last successful completion, and relevant logs. A loaded process, provider usage
meter, or `launchctl` state alone is not proof. Conversely, an on-demand agent
being unloaded or a detached helper making its launcher exit is not automatically
a failure.

## 4. Route Notifications Through One Owner

- Route recurring-job failures through Tool Status Dashboard. Follow its
  existing producer and recovery patterns; do not create a parallel notifier.
- Do not use direct shell/Python/Script Editor `display notification` calls.
  They produce the wrong application identity, weak click behavior, duplicate
  notification apps, and inconsistent icons.
- Keep success silent. Keep ordinary offline skips and expected idle silent.
- Notify once when user action is required, a real failure persists, or a
  deadline becomes endangered. Deduplicate repeated scans of the same incident.
- Put the tool name and plain-language cause in the push. Keep full evidence and
  repair guidance in Tool Status Dashboard.
- Let Tool Status Dashboard own deterministic repair and its policy-bounded LLM
  auto-fix. Keep the producer failed until its original health check passes in
  the real scheduler context; do not embed another LLM repair loop in the job.
- If no dashboard integration exists, stop and present the missing integration
  as part of the proposed scope instead of inventing another notification path.

### Dashboard tool registry

- After installing any persistent CLI or script, register it:
  `tool-status-register add <binary> [--check exists|version|help]`. Default
  `version` runs `<binary> --version` each scan (5s timeout); use `help` when
  the tool lacks `--version`; use `exists` for wrappers where any execution has
  side effects. Registered (`addedBy: agent`) entries fail loudly through the
  incident → autonomous repair → escalation path when the binary vanishes or
  the health check fails.
- The background scan also auto-registers every executable in `~/.local/bin`
  as a silent existence-only entry and auto-deregisters those after two
  consecutive scans missing. This is reconciliation, not a substitute:
  explicitly register agent-installed tools so they get a real health check
  and loud failures.
- Registry: `~/.local/state/tool-status-dashboard/registry.json`. Never edit it
  by hand or from an agent; all writes go through `tool-status-register` or the
  background scan (both serialize on `registry.lock` with atomic writes).
- To retire a tool intentionally, run `tool-status-register remove <binary>`
  before or after deleting it so no incident fires.

## 5. Install or Migrate Without Leaving Two Owners

- For cron, inspect the current crontab, replace only the uniquely marked entry,
  install interactively, and confirm unrelated entries are unchanged.
- For a LaunchAgent, validate with `plutil`, use the exact label and absolute
  paths, then bootstrap or replace it in `gui/$(id -u)` as appropriate.
- When the approved scope changes mechanisms, retire the old mechanism fully:
  unload it, remove its live schedule entry, archive a retired plist outside
  `~/Library/LaunchAgents/`, and leave exactly one owner. Stop an orphan process
  only after its PID, executable path, command line, parentage, or scheduler
  label proves that it belongs to the retired mechanism; otherwise report it
  without terminating it.
- Expect Background Items noise when installing a LaunchAgent. Do not respond by
  creating another helper or notifier.

Do not change protected project-owned mechanisms such as SchoolSync unless the
request names them. Semantic-index scheduling may change; inspect live cron and
LaunchAgent state instead of relying on a hard-coded mechanism.

## 6. Verify in the Production Context

1. Run static checks: script syntax, `plutil` for plists, configuration parsing,
   and any non-destructive self-check.
2. Run the wrapper manually to validate its functional logic.
3. Exercise the actual scheduler context. For a LaunchAgent, kickstart or await
   the real job and inspect its exit state plus artifacts. For cron, run once in
   a cron-like minimal environment and verify at least one real scheduled tick.
4. Check permissions and TCC from the scheduled context. Do not infer them from
   the interactive shell.
5. Verify failure and recovery reporting through Tool Status Dashboard when a
   safe synthetic path exists; do not generate a user-visible test alert merely
   to claim coverage.
6. Reinspect cron, LaunchAgents, processes, and dashboard inventory for
   duplicates, orphans, false failures, and collateral changes.
7. State what passed and what remains unverified, especially reboot, sleep/wake,
   offline recovery, authentication expiry, and long-interval timing.

Report the mechanism, cadence, wrapper, state/log paths, owner, retry behavior,
notification behavior, retirement actions, scheduler-context evidence, and any
remaining unverified condition.

</workflow>

<scope-control>

Creating or repairing one background job does not authorize changes to other
jobs, global notification settings, third-party LaunchAgents, or protected
project schedulers. Diagnose neighboring problems read-only and request fresh
scope before changing them.

</scope-control>
