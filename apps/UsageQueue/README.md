# UsageQueue

Queue a message into an existing Codex task; it delivers the moment usage/rate limits reset.

- **App:** `/Applications/UsageQueue.app` — pick a Codex task, type a message, and queue it. The right panel shows job status (waiting for usage reset → delivered) and lets you cancel.
- **Backend:** `~/.local/bin/queue-when-usage` (python3, standard library only). `sessions codex --json`, `add codex`, `jobs --json`, `cancel <id>`. State + logs: `~/.local/state/queue-when-usage/`.
- **How it works:** a detached runner tries `codex exec resume <id> "msg"` immediately, and while Codex reports a usage limit it waits for the recorded reset before retrying (24h cap). Success and failure route through Tool Status notifications.
- **Build:** `./scripts/build.sh` (CLT-only swiftc; signs "Ivo Market Dev"; installs to /Applications; `NO_DEPLOY=1` to skip).

## Destination and colour

The only lane is Codex. Tasks come from `~/.codex/state_5.sqlite`, and the established OpenAI teal drives the selected task, model controls, job chips, and send button.
- **Gotchas:** see `.memory/wiki/overview.md` (codex binary version, `--skip-git-repo-check`, autonomy flags).
- **Version control:** this repo commits and pushes itself nightly via `app-repo-sync`; changes are grouped by scope (sources / build / resources / docs) into separate commits. History before 2026-08-06 was replayed from a daily-snapshot archive, so those commits are day-granular.
