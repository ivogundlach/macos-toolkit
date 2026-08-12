---
name: scriptify
description: >-
  Use when Ivo asks to scriptify or automate a repeated AI-performed action,
  says "turn this into a script," or wants to find tasks that should run as
  deterministic code instead of spending model tokens. Isolate the mechanical
  core, mine recent Codex logs when discovery is requested, build a
  reusable local or project script, verify its direct invocation, and record it
  for future agents. For scheduling the finished script, also use
  macos-background-jobs. Skip judgment-heavy workflows and genuine one-offs.
---

# Scriptify

Replace repeatable model work with deterministic code. The result is complete
only when a future agent can call one stable command instead of rereading
context, reconstructing steps, and spending tokens on the same mechanical
action.

## Qualifying Test

Script the smallest mechanical core that passes all of these checks:

- **Token displacement:** future use becomes a direct invocation, not another
  model-generated procedure.
- **Determinism:** explicit inputs produce predictable outputs and side effects.
- **Recurrence:** the action already repeats or is plausibly about to repeat.
- **Stable boundary:** success, failure, permissions, and destructive effects
  can be expressed and checked in code.
- **No existing replacement:** an installed tool or script does not already
  provide the same reliable interface.

Keep variable judgment outside the script. A workflow may still qualify when
only its mechanical portion can cross the token boundary.

## Choose the Mode

### Direct replacement

When Ivo identifies a specific action and asks to scriptify it, treat that
request as approval to build the scoped replacement. Inspect the current manual
or agent-executed path, define its inputs and outputs, and implement it without
pausing at a proposal.

### Discovery

When Ivo asks what should be scriptified, run the bundled local miner:

```bash
python3 "/Users/YOUR_USERNAME/.codex/skills/tool skills/scriptify/scripts/mine-logs.py" --days 30 --top 15
```

The miner parses logs locally and emits only normalized patterns plus aggregate
counts. Judge the results semantically; frequency is evidence of repetition,
not proof that a script is useful. Prefer patterns repeated across distinct
sessions and days. Present a short table with the action, proposed invocation,
what model work it replaces, payoff (`high`, `medium`, or `low`), and risk.
Build only candidates Ivo approves.

## Build the Replacement

1. Search existing scripts and installed tools before adding code.
2. Put Ivo-wide commands in `~/.local/bin`; put project-specific commands in
   the project's existing `scripts/` directory.
3. Prefer the standard library and the smallest maintainable implementation.
4. Give the command a stable interface: `--help`, explicit arguments,
   meaningful exit codes, results on stdout, and actionable errors on stderr.
5. Make repeated execution safe. Require an explicit flag for destructive or
   materially state-changing behavior when silent repetition would be unsafe.
6. Do not call Codex, an LLM API, or another model from the replacement.
   Such a wrapper may automate orchestration, but it has not eliminated token
   use and must not be reported as a successful scriptification.
7. If the script must run on a schedule or in the background, finish the worker
   here and use `macos-background-jobs` for scheduler ownership and runtime
   verification.

## Verify and Hand Off

- Run the exact future invocation, including a representative success case and
  the smallest material failure case.
- Compare the observable result with the action being replaced.
- Confirm the installed command itself has no model dependency.
- Inspect permissions and collateral changes before claiming completion.
- Capture the installed command, purpose, location, inputs, and invocation as a
  workflow fact through `memory-capture`, cite it in the relevant wiki page,
  and run `memory-lint`.
- Register the installed command with `tool-status-register add <binary>
  [--check exists|version|help]` so Tool Status Dashboard monitors it
  (mechanics in `macos-background-jobs`).

Do not invent precise token-savings figures without measurements. Report what
future model work the command removes and how often the evidence suggests it
will run.

## Privacy

Never load raw session transcripts into model context. The miner reads them
locally, recognizes explicit shell-tool records, and emits normalized command
signatures containing only executable basenames, allowlisted generic
subcommands, option names, and opaque markers for interpreter script paths—
never raw command bodies or free-form argument values. Missing or malformed
sources are counted in coverage output rather than silently treated as proof
that no candidates exist.
