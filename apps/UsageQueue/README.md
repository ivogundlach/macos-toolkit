# UsageQueue

Queue a message into an existing Claude Code or Codex thread; it delivers the moment usage/rate limits reset.

- **App:** `/Applications/UsageQueue.app` — pick agent, pick thread (parsed from local session stores), type message, Queue. Right panel shows job status (waiting for usage reset → delivered) and lets you cancel.
- **Backend:** `~/.local/bin/queue-when-usage` (python3, stdlib only). `sessions <claude|codex> --json`, `add`, `jobs --json`, `cancel <id>`. State + logs: `~/.local/state/queue-when-usage/`.
- **How it works:** a detached runner tries `claude -p --resume <id> "msg"` / `codex exec resume <id> "msg"` immediately, and while the CLI errors with a usage-limit message it retries every 10 min (24h cap). Success/failure notifies via terminal-notifier.
- **Build:** `./scripts/build.sh` (CLT-only swiftc; signs "Ivo Market Dev"; installs to /Applications; `NO_DEPLOY=1` to skip).

## Lanes

A *lane* is the harness a message is delivered to. Three exist, all fully supported by the backend:

| Lane | Backend destination | Sessions read from |
|---|---|---|
| Claude Code | `claude` | Claude Code CLI/desktop session store |
| Codex | `codex` | `~/.codex/state_5.sqlite` |
| T3 Code | `claude` | `~/.t3/userdata/state.sqlite` |

T3 Code is a Claude surface, not a separate provider — it queues to the same `claude`
destination and differs only in which store its threads are read from.

### Hiding a lane

`hiddenNewThreadKinds` in `Sources/main.swift` controls **only** which lanes appear in the
New thread picker. It disables nothing: queuing, resuming, restoring, and listing threads
for a hidden lane all keep working, and rows for a hidden lane still appear in the thread
list whenever the backend returns them. `visibleNewThreadKind()` remaps a hidden lane onto
the visible lane sharing its backend, so a stored preference or a restored failed job never
selects an invisible button.

This install ships with `["claude"]` hidden, because Claude is driven exclusively through
T3 Code here. **If you use the Claude Code desktop app or the `claude` CLI, set
`hiddenNewThreadKinds` to `[]` and rebuild** — the lane returns with no other changes needed.

## Colour

Two independent axes, deliberately not merged:

- **Lane** — Claude Code orange, Codex teal, T3 Code steel. Drives thread chrome: the
  selected-thread slab, lane badges, the send button.
- **Lab** — whoever makes the model. Anthropic orange, OpenAI teal. Drives every place a
  model is *named*: the model text on thread rows, the queued-job model chip, and the whole
  Model block in the composer.

They agree inside the Claude and Codex lanes and diverge inside T3 Code, which is a harness
rather than a lab — so a T3 thread running Opus reads steel for the lane and Anthropic
orange for the model. `agentColor()` and `labColor(forModel:fallback:)` are the two entry
points; an unrecognised model falls back to the lane colour rather than inventing a hue.
- **Gotchas:** see `.memory/wiki/overview.md` (codex binary version, `--skip-git-repo-check`, autonomy flags).
- **Version control:** this repo commits and pushes itself nightly via `app-repo-sync`; changes are grouped by scope (sources / build / resources / docs) into separate commits. History before 2026-08-06 was replayed from a daily-snapshot archive, so those commits are day-granular.
