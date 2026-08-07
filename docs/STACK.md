# The Stack

A complete map of Ivo Gundlach's macOS machine — every app he wrote, every
scheduled job, every CLI, every system tweak — written so that an agent (or a
person) landing here cold can understand how the whole thing fits together
without spelunking.

**Audience:** a coding agent given access to this machine, or a friend reading
over the design. It assumes competence but no prior context.

**Authoritative source:** the Tool Status registry
(`~/.local/state/tool-status-dashboard/registry.json`, 62 entries) is the
canonical list of installed CLIs, and `~/Library/LaunchAgents/` is the canonical
list of scheduled work. Everything below was read from those two places plus the
live system on 2026-08-06. Where this document and the machine disagree, the
machine is right — re-derive rather than trust.

---

## 0. Reading order

If you only read three sections: [§1 Control plane](#1-the-agent-control-plane)
tells you the rules you are operating under, [§5 Scheduled
automation](#5-scheduled-automation) tells you what is running behind your back,
and [§11 Landmines](#11-landmines) tells you what breaks if you touch it wrong.

---

## 1. The agent control plane

Agents are the primary way work gets done on this machine. Their behaviour is
governed by a layered configuration:

| Layer | Path | Role |
|---|---|---|
| Global rules | `~/.codex/AGENTS.md` (27 KB) | The constitution. Sections: 0 Control Plane, 1 Interaction/Authority/Review, 2 Tools and Reliability, 3 Hidden Auto Memory, 4 Data and Deliverables |
| Skills | `~/.codex/skills/<category>/<skill>/` | 56 procedural playbooks across 5 categories |
| Claude mirror | `~/.claude/skills/`, `~/.claude/settings.json` | Generated — never edit directly |
| Auto memory | `~/.claude/projects/-Users-ivogundlach/memory/` | ~60 one-fact files + `MEMORY.md` index, loaded into every session |

### Skill authoring is one-directional

**Skills are authored in `~/.codex/skills/<category>/` and only there.** After
writing or editing one, run `codex-to-claude-sync`, which mirrors them into
`~/.claude/skills/` and the Gemini location, *and prunes anything that no longer
exists upstream* (with an empty-source safety guard so a failed read can't wipe
the mirror). Writing directly into `~/.claude/skills/` produces a file that the
next sync deletes.

The five categories and their contents:

(Counts below exclude each category's `config` directory.)

- **workflow skills** (20) — `vibe-coding` (the default builder), `github-workflow`,
  `improve-system`, `peer-review`, `design-taste`, `handoff`, `wayfinder`,
  `web-research`, `teach`, `grill-with-memory`, `ivo-writer`, `skill-audit`,
  `macos-background-jobs`, `apple-mail-reply-drafter`, `twitter-ingest`,
  `yt-dlp-fetch`, `watch`, `jdownloader-watch-later`, `uah-degree-plan-workflow`,
  `codex-claude-sync-check`
- **cybersecurity-skills** (14) — LLM red-teaming (`garak`, `promptfoo`), prompt
  injection detection and testing, RAG pipeline injection, guardrails, model
  extraction, data/model poisoning, malicious npm packages, malicious URL analysis
  via urlscan, phishing email header analysis, agentic tool-invocation security,
  system prompt leakage, embedding/vector weaknesses
- **google skills** (11) — Workspace: gmail (+read, +triage), calendar (+agenda),
  docs, drive, sheets, tasks, people, shared
- **tool skills** (8) — `playwright-cli`, `exa-search`, `firecrawl`,
  `notebooklm-py`, `cli-anything`, `drawio-skill`, `scriptify`, `last30days`
- **second brain skills** (4) — `auto-remember`, `memory-audit`,
  `local-read-connectors`, `project-memory-init`

A weekly job (`skill-drift-check`, Sundays 17:30) writes
`~/.local/state/skill-drift/report.md`, which the `improve-system` skill consumes
as its work queue. **Skills are fixed with general principles, never with
grader-specific tactics** — benchmaxing a skill to a particular eval is an
explicit anti-goal.

### Agent surfaces in use

- **T3 Code** (`/Applications/T3 Code (Nightly).app`) — the primary surface.
  Electron, Effect-TS server, event-sourced SQLite (`~/.t3/userdata/state.sqlite`).
  The Claude Code desktop app and `claude` CLI are **not** used interactively;
  Claude is driven through T3.
- **Codex** — via the ChatGPT desktop app and the `codex` CLI. T3 also ships
  Codex as a *built-in provider* (`DEFAULT_PROVIDER_DRIVER_KIND = "codex"`), and
  `thread/resume` on `codex app-server` accepts **any** thread id — including one
  created by ChatGPT.app. Caveat: T3 reads only `.id`/`.cwd`/`.model` from the
  resume response and discards the returned turns, so the model keeps full
  context but T3's transcript pane renders empty. A failed resume silently falls
  back to `thread/start`, creating an unrelated fresh thread.
- Others present: `grok`, `cursor-agent`, `opencodex`/`ocx` (local proxy on
  :10100), `agent`, `luna-implement`, `reviewer`, `claude-high-fidelity`.

**Browser automation is Playwright, always.** The Claude-in-Chrome extension
tools are not to be used.

---

## 2. Memory system

Two distinct systems that are easy to confuse.

### 2a. Auto memory (curated, small)

`~/.claude/projects/-Users-ivogundlach/memory/` — roughly 60 markdown files, one
fact each, with YAML frontmatter (`name`, `description`, `metadata.type` of
user/feedback/project/reference). `MEMORY.md` is a flat index of one-line
pointers loaded into every session. Files link each other with `[[wiki-links]]`.

These encode hard-won operational knowledge — the kind of thing that costs a day
to rediscover. Examples: *"never point launchd at bare python (anonymous BTM
re-announcements)"*, *"sign personal apps with the Ivo Market Dev cert so TCC
grants survive rebuilds"*, *"CGWindowList not AX kAXWindows for window counting"*.

### 2b. Semantic corpus (large, searchable)

`~/.memory/` — a hybrid retrieval system over Ivo's documents, notes, and chat
transcripts.

- **Storage:** `semantic-index.sqlite` (FTS5, with `docs` marked UNINDEXED),
  plus memmapped `.npy` vector files for the dense arm
- **Architecture:** BM25 + dense vectors, RRF-fused, then a cross-encoder rerank
  stage. A third arm embeds agy-*generated questions* and matches query↔question
  in one symmetric space
- **Latency:** a warm `memory-query-daemon` exists because ~95 ms of Python
  imports per query can't be optimised away; ~65 ms of any cold query is
  interpreter startup. The daemon is never load-bearing (`None ≠ []`)
- **Scale:** kNN is a memmapped BLAS gemv, not an ANN index — the old ceiling was
  a per-row constant, not an asymptote, so exact search is 8× faster at every
  size. ANN was rejected deliberately
- **Scope:** prose only. Embedding code bodies scored *worse* than no vector arm
  at all; code *questions* help. This is baked into the index fingerprint
- **Confidentiality:** there is no secrets denylist. A denylist dropped 23 of
  Ivo's own files because a filename mentioning credentials is a claim about
  *topic*, not a live key. Redaction happens at the agy upload boundary instead
  (`redact_secrets()`) — a gate can only drop a file, redaction keeps it
  searchable
- **Quality bar:** `memory-retrieval-eval` runs weekly recall@k, currently
  62%/88% on 112 cases against an 80% bar. The corpus moves under the benchmark,
  so any claimed delta must be measured against a same-day control run

Commands: `memory-search`, `memory-semantic-query`, `semantic-index-status`,
`memory-selftest` (contract tests pinning invariants that break *invisibly*).

---

## 3. Applications Ivo wrote

All SwiftUI, all built with **Command Line Tools only — no Xcode**. Each has a
`scripts/build.sh` that compiles with `swiftc` and code-signs. Sources live in
`~/Projects/<App>/`, and each is its own private GitHub repo (see §7).

| App | Repo | What it does |
|---|---|---|
| **Market** | `Market` | Market regime analysis, options flow, scheduled data pulls |
| **Vitals** | `Vitals` | Activity Monitor replacement — GPU tab, per-process energy in mW, battery-drain Findings, SQLite history, opt-in root helper |
| **Tool Dashboard** | `ToolStatusDashboard` | Health dashboard for every CLI and job on the machine (see §4) |
| **UsageQueue** | `UsageQueue` | Queues a message into an existing Claude/Codex thread; delivers at usage-limit reset |
| **Psephos** | `ElectionSimulator` | Election simulator — Senate chaining, House ballot, apportionment, EV map, geo-redistricting, Monte Carlo |
| **NutrientTracker** | `NutrientTracker` | Nutrition logging |
| **Kinetics** | `Kinetics` | Physics/motion tool |
| **MacroSimulator** | `MacroSimulator` | Macroeconomic simulation |
| **CanIAffordThis** | `CanIAffordThis` | Purchase-affordability calculator |
| **Warm Corners** | `WarmCorners` | Hot-corners clone with a per-corner dwell delay; imports the App Store Hot Corners config |
| **CopyPath** | `CopyPathFinder` | Finder Sync extension adding a top-level "Copy Path" |
| **School / SchoolSync** | `School` | UAH course sync; EventKit access only via the `SchoolSync.app` bundle |
| **Tax Simulator** | *(in Personal-Repo)* | Tax modelling |
| **AutoInstall DMG** | *(no repo — edit `main.scpt` in place)* | Droplet that mounts, installs, and ejects DMGs; serialized via a detached `worker.sh` |
| **Knockoff** | `knockoff-local` | Safari extension, CLT-built app extension |

### Safari extensions (all CLT-built, all his)

`ForceCopyPaste` (per-site copy/paste unblocker), `NewTabLinks` (external links →
new tab), `YouTubeHomeReload` (logo click → full home reload),
`YouTubeFirstContentTab`, `Knockoff`.

**Critical:** a Safari app extension must carry the sandbox entitlement or `pkd`
silently ignores it — no error, it just never appears. Sign with the **Apple
Development** certificate (team `Q2X7X86GYR`), *not* the Ivo Market Dev cert; then
no "Allow Unsigned Extensions" toggle is needed and the extension survives
restarts.

### Design language

Every personal app carries a tokens enum derived from UsageQueue's
(`MarketUI`, `HealthUI`, `TaxLabTheme`, `Theme`, `DashboardTheme`). **Extend
those; do not invent a new design system per app.** All 8 glassed apps target
macOS 26 with Liquid Glass. Rules learned the hard way:

- Glass on containers only
- Strokes cannot carry state on glass
- Never tint glass for a selected pill — it fails in light mode
- Layer count is the performance cost, not gradient area: 7 overlays collapsed
  into one `drawingGroup()` took Market from 7 Hz to 58 Hz
- Panels inside a `ScrollView` relight every frame they travel; hold-during-motion
  plus a settle pass took Market from 2.8 s to 1.2 s CPU and 22.2% late frames
  to 0.8%
- `ImageRenderer` is blind to all of this — measure presented vsync gaps

### Signing

Personal apps are signed with a self-signed keychain certificate named **"Ivo
Market Dev"** (a certificate, not a Developer ID identity). The point is that TCC
grants — Accessibility, Full Disk Access, Automation — survive a rebuild. An
ad-hoc-signed app loses them every time, and **ad-hoc apps cannot post
UserNotifications at all** (they fail silently) — use `terminal-notifier` instead.

---

## 4. Tool Status Dashboard

`/Applications/Tool Dashboard.app` — the machine's self-monitoring layer, and the
reason this document could be written completely.

- **Registry:** `~/.local/state/tool-status-dashboard/registry.json`, 62 tools.
  35 auto-registered by scanning `~/.local/bin`, 27 added explicitly by an agent.
  Check kinds: `exists` (39), `version` (20), `help` (3)
- **Standing rule:** after installing any CLI, run `tool-status-register add <binary>`
- **Scan:** `tool-status-background-scan` every 300 s
- **Repair:** `tool-status-repair-worker` every 60 s — an autonomous agent
  (gpt-5.6-terra, medium effort) that can fix a defined class of failures

### The repair agent's authority model

This is the most safety-sensitive machinery on the box. Five gates, each learned
from a real failure:

1. **Pinned-path recipe table** — a fix must match a known recipe, not be improvised
2. **Identity-bound write scope** — `owner_scope()` grants write authority by
   matching the incident's *owner tag*. It used to match the *display name*, which
   meant the repair agent could "fix" its own self-checks (they're named after
   their subject). Fixed with an explicit `owner` field
3. **Restart allowlist + ledger** — every restart is recorded
4. **Config-target authority** — may append exactly one candidate-selected line to
   a cause-code-pinned config file, verified *structurally*, not by exit code
5. **Autonomous-code allowlist** — two exact-path memory diagnostics, rehearsed
   under `sandbox-exec` with a throwaway `$HOME`. `run-all` is excluded because it
   grades itself. Production runs are unsandboxed

Notification rule: a card that reaches `create_request` is *by definition*
unfixed — no `none` outcome, no suppression window. A per-incident push cooldown
kills flapping.

There is **no git** in the dashboard repo's fix path; rollback is via
`appbackup-*` snapshots in `~/.local/state`.

---

## 5. Scheduled automation

25 LaunchAgents plus one crontab entry. This is the complete list.

### Ivo's jobs

| Label | Runs | What |
|---|---|---|
| `com.ivogundlach.tool-status-dashboard.scan` | every 300 s | Health scan of all registered tools |
| `com.ivogundlach.tool-status-dashboard.repair` | every 60 s | Autonomous repair worker |
| `com.ivogundlach.vitals.sampler` | KeepAlive daemon | Vitals process/energy sampling |
| `com.ivogundlach.vitals.findings` | 04:00 daily | Battery-drain findings analysis |
| `com.ivogundlach.claude-window-keeper` | every 10 min (:00–:50) | Keeps the Claude 5-hour usage window started with silent ephemeral pings. Gates on the *true reconstructed* reset with an 08:00 daily anchor. The Codex half is currently **disabled** via a plist flag. A window under 5 h is a regression |
| `com.ivogundlach.codex-auto-reset-scheduler` | 12:17 daily | Refreshes Codex reset targets. `--schedule` never consumes a credit |
| *(crontab)* `codex-auto-reset` | every minute | Poller for the above |
| `com.ivogundlach.codex-to-claude-sync` | every 24 h | Mirrors skills Codex → Claude/Gemini, pruning deletions |
| `com.ivogundlach.memory.semantic-index` | 17:00 daily | `semantic-index-retry --semantic-only`. Near-zero agy usage is *healthy* (hash cache). The graph phase was retired 2026-07-19. New captures index immediately via `--only` |
| `com.ivogundlach.transcript-distill` | 16:20 daily | Distils Claude + Codex transcripts into `~/.memory/raw/chat/distilled/`, injection- and secret-guarded, with recency decay and a stale gate |
| `com.ivogundlach.memory-corpus-backup` | 17:30 daily | `~/.memory` → private GitHub repo `memory-corpus` |
| `com.ivogundlach.memory-health-weekly` | Sun 18:15 | Index integrity, coverage, restorability, recall. Always exits 0. Every step watchdogged, because launchd has no TCC grant and `opendir` *blocks* |
| `com.ivogundlach.personal-repo-sync` | 23:30 daily | Snapshot archive → `Personal-Repo` (see §7) |
| `com.ivogundlach.app-repo-sync` | 12:30 + 22:30 daily | Per-app commit and push (see §7) |
| `com.ivogundlach.apple-mail-draft-runner` | hourly 08:00–22:00 | Drafts Mail replies. Deduped at *thread* level by reading Drafts `.emlx` files directly — Mail's index and AppleScript are both blind to drafts |
| `com.ivogundlach.quit-on-close` | KeepAlive daemon | Quits apps when their last window closes. Counts windows via `CGWindowList`, **not** AX `kAXWindows` (which under-reports and causes false quits) |
| `com.ivo.market.refresh` | every 900 s | Market background data refresh |
| `com.ivo.school-sync` | :07 hourly | UAH course sync (gated until 2026-08-15) |
| `com.ivo.notebooklm-sync` | every 3600 s | NotebookLM notebooks → markdown |
| `com.ivo.notebooklm-auth-refresh` | every 24 h | Keeps the NotebookLM session alive |
| `com.user.smartwake` | KeepAlive daemon | Sleep/wake policy from SSID trust, AC state, battery level, with override and cooldown windows |
| `com.user.smartwake.discord` | KeepAlive daemon | Discord command channel for Smart Wake |

### Third-party

`com.koekeishiya.skhd` (hotkey daemon), `com.opencodex.proxy` (local agent proxy
on :10100), `com.google.keystone.*` (Chrome updater).

### The rule this whole layer is built on

**Health-check the output, not the run.** The nightly semantic index once did
nothing for three consecutive nights and exited 0 each time — an orphaned `mkdir`
lock, and no dashboard card. Related failure modes, all real:

- A check reading `launchd` `LastExitStatus` after a manual run reported 721
  consecutive failures that never happened
- `sqlite` `immutable=1` skips the `-wal`, so a health check using it read a
  pre-checkpoint snapshot and kept reporting a *fixed* corruption as broken. Try
  `mode=ro` first
- A `waitUntilExit()` before draining stdout deadlocked forever once the payload
  exceeded the ~64 KB pipe buffer, holding `scan.lock` indefinitely
- Display caps are never health states: an over-broad process needle matched 127
  apps and blew a 40-row cap every scan, which surfaced as a warning

Locks are **atomic pid-carrying symlinks**, and a stale lock is only cleared after
confirming the owner process is actually dead.

**Never point launchd at a bare `python` binary** — it triggers anonymous
Background Task Management re-announcements and a stream of system notifications.
Use a stamp-gated wrapper script or a signed `.app` bundle.

---

## 6. The CLI fleet

80 executables in `~/.local/bin`, 62 registered with Tool Status. Grouped by job:

**Memory / retrieval (17)** — `memory-search`, `memory-semantic-query`,
`memory-query-daemon`, `memory-semantic-build`, `memory-vector-build`,
`memory-index-check`, `memory-selftest`, `memory-retrieval-eval`,
`memory-coverage-drift`, `memory-health-weekly`, `memory-prune`,
`memory-secret-scan`, `memory-backup-verify`, `memory-corpus-backup`,
`memory-transcript-distill`, `semantic-index-retry`, `semantic-index-status`,
`semantic-corpus`, `semantic-agy-notify`, `semantic-agy-reauth`, `agy`

**Agents / coding (12)** — `agent`, `codex`, `grok`, `cursor-agent`, `opencodex`,
`ocx`, `omlx`, `cli-hub`, `luna-implement`, `reviewer`, `claude-high-fidelity`,
`peer-review` helpers

**Codex/Claude plumbing (6)** — `codex-auto-reset`, `codex-to-claude-sync`,
`codex-sync-verify`, `codex-skill-audit`, `codex-code-mode-host`,
`claude-window-keeper`

**Version control / backup (4)** — `personal-repo-sync`, `app-repo-sync`,
`app-repo-bootstrap`, `app-repo-lib.sh`

**Tool Status (4)** — `tool-status-register`, `tool-status-background-scan`,
`tool-status-notify`, `tool-status-repair-worker`

**Mail (4)** — `apple-mail-draft-assistant`, `apple-mail-draft-runner`,
`apple-mail-rowid-body`, `apple-mail-trash-hide-email-audit`, `school-mail`

**Content ingest (6)** — `exa-search`, `arxiv-pp-cli`, `digg-pp-cli`,
`techmeme-pp-cli`, `last30days`, `kiwix-search`/`kiwix-serve`/`kiwix-manage`
*(kiwix is retired — see §11)*

**System (10)** — `queue-when-usage`, `quit-on-close`, `copy-safari-url`,
`refresh-app-icons`, `mac-process-audit`, `market-cron`, `market-refresh`,
`vitals-findings`, `school-sync`, `studykit`, `smart-wake`, `swift-smoke`,
`skill-drift-check`, `improve-system-log`, `cyber-skill-triage`, `swiftlint`

**Standing rule:** never silently work around a broken tool in conversation. If a
registered tool is broken, that is a finding to surface, not an obstacle to route
around.

---

## 7. Version control and backup topology

Three independent mechanisms, deliberately non-overlapping.

### 7a. Per-app repositories — `app-repo-sync` *(primary, since 2026-08-06)*

Sixteen apps, each with its own **private** GitHub repo under `g2pxg4mff4-wq`,
with real per-change history.

- **Bootstrap:** `app-repo-bootstrap` replayed history from the Personal-Repo
  snapshot archive — one dated commit per archived snapshot, message
  `Snapshot YYYY-MM-DD` — into a scratch tree, then adopted that `.git` into the
  live working tree. It never rsyncs old snapshots over live files
- **Nightly:** `app-repo-sync` at 12:30 and 22:30. Changed files are bucketed by
  scope (`sources` / `build` / `resources` / `docs` / `chore` / `misc`) and each
  scope gets **its own commit**, with a message written by a Haiku call reading
  the actual staged diff. A night touching both the UI and the build script
  produces two focused commits, not one blob
- **Inference is never load-bearing:** if the model is unreachable, slow, or
  returns garbage, a deterministic fallback message is used and the commit still
  lands. Backup must not depend on inference succeeding
- **Gates, all fail-closed, run per commit before it is written:** sensitive-path
  check, `gitleaks` on the staged set, and a deletion circuit breaker
  (max 25 files or 20% of tracked). A blocked scope is left *uncommitted* for
  review rather than committed and reverted
- **Two intervals, not one,** because the 23:30 archive job has been missing runs
  while the Mac is asleep. `RunAtLoad` is true and the job is idempotent, so a
  login recovers a missed slot

Excluded on purpose: `AmethystFork` (a fork with upstream history) and the
third-party clones `CLI-Anything`, `CodexBar`, `knockoff`, `claude-video` — those
are mirrored separately as `*-local` repos.

### 7b. Snapshot archive — `personal-repo-sync` *(backstop)*

`g2pxg4mff4-wq/Personal-Repo`, nightly at 23:30. A daily full-tree snapshot of
apps, scripts, skills, and automation source. It excludes `.git/`, so per-app
history is invisible to it and the two systems never interfere.

`~/Projects/Personal-Repo` on disk is a **control surface only** — its working
tree is routinely dirty and its last local commit is old. Every run uses a fresh
shallow clone. Reading the local checkout to judge the backup's health is a
category error (and exactly the "reading a proxy instead of real state" trap
documented in §11).

### 7c. Memory corpus — `memory-corpus-backup` *(daily 17:30)*

`~/.memory` → private repo `memory-corpus`. This was added 2026-07-25 after
discovering the curated notes had **no backup anywhere** — three backup
mechanisms existed and none covered them. A successful push is not a proven
restore; `memory-backup-verify` exists for that.

### 7d. Repository inventory — as of 2026-08-06

**22 repositories, all private. There is no public repository.**

Per-app: `CanIAffordThis`, `CopyPathFinder`, `ElectionSimulator`,
`ForceCopyPaste`, `Kinetics`, `MacroSimulator`, `Market`, `NewTabLinks`,
`NutrientTracker`, `School`, `ToolStatusDashboard`, `UsageQueue`, `Vitals`,
`WarmCorners`, `YouTubeFirstContentTab`, `YouTubeHomeReload`.
Archive: `Personal-Repo`, `memory-corpus`.
Third-party mirrors: `CLI-Anything-local`, `CodexBar-local`, `knockoff-local`,
`claude-video-local`.

### 7e. The public toolkit candidate

`Personal-Repo/scripts/build-public-toolkit.py` (47 KB) builds a *sanitized
public source candidate* from an immutable private snapshot. It is an exporter
and nothing more — **it never publishes, and it never creates GitHub state.** It
reads one clean checkout, copies only policy-classified UTF-8 text, performs one
exact home-prefix substitution (`/Users/YOUR_USERNAME` → `/Users/YOUR_USERNAME`),
and writes generated metadata. It never imports or executes component source.

It carries its own secret detectors: generic API-key assignments, Discord
webhooks and tokens, private `file://` URIs, `/Users/*/.memory` paths, private
temp and cache paths. Output is a separate empty directory and stays a
*candidate* until its manifest, secret scan, and component verification have been
reviewed by a human.

Templates live in `Personal-Repo/public/`: `README.md`, `LICENSE`,
`CONTRIBUTING.md`, `SECURITY.md`, `export-policy.json`.

**Status: no candidate has ever been built, and no public repo exists.** The
scaffolding is real and complete; nothing has been exported or published.

---

## 8. Third-party applications

**Window management:** Amethyst (running a personal fork —
`~/Projects/AmethystFork`, 0.24.3, fixing windows dropping out of tiling),
DockDoor, Ice 2, Command X, Warm Corners (his), Launchie, PeekX.

**Menu bar / system:** Itsycal, Maccy (clipboard), Hyperkey, KeyboardCleanTool,
Macs Fan Control, coconutBattery, BetterDisplay, BrightIntosh, boringNotch,
Caffeine, TinkerTool, OnyX, GrandPerspective, Find Any File, Latest, ImageOptim,
Keka, LocalSend, TextSniper, WhatCable.

**Browsing / privacy:** Safari (primary), 1Blocker, AdGuard for Safari, Hush,
Noir, SponsorBlock, Turn Off the Lights, Cold Turkey Blocker, BlockerX,
Grammarly, LanguageTool, Surfshark, Hotspot Shield, Tailscale.

**AI:** ChatGPT.app, Claude.app, Gemini.app, T3 Code (Nightly), CodexBar,
OpenCode, AnythingLLM, oMLX, Antigravity, Cotypist, Cotabby, aionui.

**Media / transfer:** IINA, JDownloader 2, Transmission, MovieBoxPro, o3IPTV,
iloader, PlayCover, Steam, WeTransfer, Unsplash Wallpapers.

**Productivity:** Microsoft Word/Excel/Teams, Pages, iMovie, OneDrive, PDFgear,
draw.io, Marked, MarkEdit, TradingView, Zoom, Discord, Warp, Xcode-beta.

**Homebrew:** 115 formulae. Notable: `gh`, `git`, `gitleaks`, `gnupg`, `go`,
`rust`, `deno`, `bun`, `node`, `python@3.11`–`@3.14`, `llvm`, `swiftlint`,
`skhd`, `tailscale`, `terminal-notifier`, `yt-dlp`, `duti`, `mas`, `graphviz`,
`poppler`, `lightpanda`, `omlx`. Casks: `aionui`, `codexbar`, `drawio`,
`gcloud-cli`, `keka`, `marked-app`, `markedit`, `tailscale-app`, `thaw@beta`.

---

## 9. macOS customizations

The small stuff, which is exactly the stuff nobody writes down.

### Sound

- **UI sound effects are globally off:** `com.apple.sound.uiaudio.enabled = 0`.
  This is the single switch that kills the **charging chime**, the Trash-empty
  sound, the screenshot shutter, and every other system effect
- `com.apple.PowerChime` is **not loaded and not running**; the domain carries
  `ChimeOnNoHardware = 1`

### Dock

- `autohide = 1`, `autohide-delay = 0`, `autohide-time-modifier = 0.5` — hides
  instantly, reveals in half the default time
- `tilesize = 67`, `magnification = 0`
- `show-recents = 0` — no recent-applications section
- `mineffect = scale` (not genie)
- `expose-group-apps = 1`
- **`mru-spaces = 0`** — Spaces do not auto-rearrange by recent use. Required for
  Amethyst tiling to stay predictable

### Hot corners

All four system corners set to `1` (no-op): `wvous-tl/tr/bl/br-corner = 1`.
Corner behaviour is handled by **Warm Corners** instead, which adds a per-corner
dwell delay. **The two conflict if both are active** — that's why the system ones
are neutered rather than left configured.

### Finder

- `FXPreferredViewStyle = Nlsv` — list view by default
- `ShowPathbar = 1`, `ShowStatusBar = 1`
- `FXDefaultSearchScope = SCcf` — search the current folder, not the whole Mac
- Top-level **"Copy Path"** in the context menu, via his own `CopyPath` Finder
  Sync extension

### Global

- `AppleInterfaceStyle = Dark`
- `AppleShowAllExtensions = 1` — always show file extensions
- `AppleScrollerPagingBehavior = 1` — click the scrollbar track to jump to that
  spot rather than page
- Text substitutions all left **on** (smart quotes, dashes, capitalization,
  spelling)

### Menu bar clock

`ShowDayOfWeek = 1`, `ShowSeconds = 1`, `ShowAMPM = 0`, `ShowDate = 0`,
`FlashDateSeparators = 0` — 24-hour, day of week, seconds, no date.

### Hotkeys

`skhd` (`~/.config/skhd/skhdrc`) binds **⇧⌘C in Safari only** to
`~/.local/bin/copy-safari-url`, which copies the front tab's URL. Scoped to
Safari so ⇧⌘C keeps its normal meaning everywhere else. This replaced an
Automator Quick Action — the lag there was the Services launcher, not the script.

### Shell

`~/.zshrc` sources the opencodex hook; the real config is
`~/.config/zsh/.zshrc` (custom `ZDOTDIR`). It sets `PATH` to include
`~/.local/bin`, `~/.omlx/bin`, `~/.grok/bin`; aliases `omlxon`/`omlxoff`; loads
NVIDIA API keys **from the macOS Keychain** via `security find-generic-password`;
and reasserts `HISTFILE=~/.local/state/zsh/history` after the system zshrc, which
otherwise relocates it relative to `ZDOTDIR`.

### Smart Wake

`~/.config/smart-wake/` — a sleep/wake policy daemon. Decides whether to keep the
Mac awake based on the current Wi-Fi SSID against a trusted list, AC power state,
battery level, an override window, and a cooldown. Includes a root sleep-guard
component and a Discord bot channel for remote commands. Status is written as a
shell-quoted key/value file so other jobs can source it.

---

## 10. Conventions

- **`~/Files` holds requested deliverables only.** No loose files, no unsolicited
  reports, no backend scratch. Subdirectories: `College`, `Docs`, `Files`,
  `Notebook LM Inbox`, `YouTube`. The rule is enforced in `AGENTS.md` §2
- **Chat file links must be relative to `/Users/YOUR_USERNAME`.** For files under
  `~/.memory/`, write `.memory/raw/chat/…` or an absolute path — never the
  memory-root-relative form. This is a recurring bug; verify with `ls`
- **Build vs install:** several `build.sh` scripts compile *and* deploy to
  `/Applications` in one step (Market, WorldCup2026). `NO_DEPLOY=1` skips the
  deploy
- **Apps live in `/Applications`.** `~/Applications` was emptied in favour of a
  single location; deploy targets and both LaunchAgents were updated to match
- **Ingest convention:** raw source first → `memory-capture` → cite by `mem_` id.
  A flat wiki restructure was evaluated and rejected (search is capped and
  line-granular)
- **iMessage, not WhatsApp.** Never suggest or mention WhatsApp. Recovering a
  "sent link" means `chat.db` plus email; iMessage rich-link URLs must be decoded
  from the binary `attributedBody` field, not just `text`

---

## 11. Landmines

Things that have already cost real time. Each of these is a rule with a corpse
behind it.

**Build and signing**

- `MacroSimulator` has **no** `build.sh` and `swift build` **fails** (Swift 6
  errors in AgyChat). Use `swiftc -swift-version 5` plus an adhoc codesign
- **Never loop `AmethystFork/build.sh`** — each build revokes the Accessibility
  TCC grant. `xcodebuild test` also pollutes the preferences domain
- SwiftPM `swift build` works under CLT 6.4, but SwiftUI `@State` still likely
  needs the ViewState/Observation workaround (not retested)
- An app that flips `LSUIElement` → `.regular` at launch needs an explicit
  `NSApp.activate()`, or its window opens *behind* everything

**macOS 26 regressions**

- The macOS 26 target bump broke `List` selection via `.tag(x as T?)`
- It also added heavy accent focus rings — apply `.focusEffectDisabled()` once at
  each window root
- Never wrap a selection change in `withAnimation`

**Health checks and measurement**

- Reading a **proxy** instead of real state has produced four separate phantom
  failure streaks (721/576/462/420 failures): launchd `LastExitStatus` after a
  manual run, `import numpy` as a venv identity check, a secret rule blind to the
  assigned value, and a fail-closed manifest
- A harness that scores a **crash** as a bad result reports a broken tool as a
  quality problem — it nearly caused a working rerank feature to be deleted
- A knob that boosts a document class, swept on a benchmark two-thirds composed
  of that class, measures the benchmark and not the knob. Count the composition
  before trusting any class-level parameter
- `sqlite` `immutable=1` is a **stale read** — it skips the `-wal`. Try
  `mode=ro` first
- Validate a derived cache on an **epoch bumped by every write**, not on a
  fingerprint — a fingerprint names the model, not the data

**Daemons**

- A socket path is not an identity. A `memory-query-daemon` started against a
  different `SEMANTIC_DB` squatted the default socket and fused foreign chunk ids
  into live searches with no error. `foreign` is tracked as a distinct telemetry
  state from `absent`, because the two have opposite repairs
- Draining stdout must precede `waitUntilExit()`; the pipe buffer is ~64 KB

**Data model**

- **Never write T3's `projection_*` tables directly** — they are projections of an
  event-sourced `orchestration_events` store and direct writes get clobbered
- Count windows with `CGWindowList`, never AX `kAXWindows`

**Secrets**

- API keys live in the **login Keychain**, never exported from a shell rc.
  `exa-search` reads service `exa-EXA_API_KEY`; `last30days` reads
  `last30days-EXA_API_KEY` — *different service names for the same key*, so
  storing only one silently breaks the other. NVIDIA keys load via
  `security find-generic-password` in `~/.config/zsh/.zshrc`
- An exported `EXA_API_KEY` **overrides** the Keychain copy (`credential_source:
  environment`), so a stale export masks a correct Keychain value
- **`security add-generic-password -w` does not read the password from stdin.**
  Piping to it exits 0 and stores an *empty* password. The value must be passed
  as an argv parameter, and any write should be read back before reporting
  success — this bug made `exa-search auth-store` report `{"ok": true}` while
  storing nothing (fixed 2026-08-06 with a round-trip verification)

**Known open issues**

- The NotebookLM sync gate mislabels network/DNS outages as "AUTH EXPIRED"
- Market's pre-market "empty SPY chain volumes" is a Yahoo backfill lag, not a
  scraper fault — classified `pending_session`, not a failure, and retrying can
  never fix it. Don't wall-clock-bound that state, and don't validate only the
  call side (`pc_vol = 0.0` scores maximally bullish)

**Retired — do not recreate**

`kiwix`, `optiq`, and `pm2` LaunchAgents plus `~/.pm2` were removed 2026-07-03.
The semantic index's **graph phase** was retired 2026-07-19.

---

## 12. What is deliberately not in this document

No credentials, tokens, API keys, cookies, or session state. Where a mechanism
needs a secret, this document names the *mechanism* and the *retrieval path*
(Keychain item, pairing flow) rather than the value.

Runtime state directories are excluded from every repository by name rather than
left to the secret scanner: `Market/state/` (1.5 GB, including a browser
profile), `School/sync/browser_profile/`, `School/sync/storage_state.json` (a
logged-in Playwright session), and all `.venv/`, `venv/`, `site-packages/`,
`node_modules/`, `*.sqlite`, `*.db`, `*.pem`, `*.key`, `*.p12`.

---

*Generated 2026-08-06 from the live machine. Regenerate rather than edit if it
drifts: the Tool Status registry and `~/Library/LaunchAgents/` are the two
sources that make a complete regeneration possible.*
