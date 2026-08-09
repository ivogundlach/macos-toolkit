# Ivo's macOS Stack

This repository is the public, agent-readable map of how Ivo uses a Mac. It
covers the visible layer—applications and interfaces—as well as the machinery
underneath: command-line tools, custom apps, scripts, scheduled jobs, agent
configuration, and reviewed macOS settings. It is designed for selective
adoption. It is not an install-everything script or a claim that a clean-machine
restore has been fully verified.

“Comprehensive” describes the map and its accounting: every discovery surface
has a visible status. It does not mean every preference, private data store, or
currently unexportable component is published. `pending_review` and `excluded`
entries are part of the result, not claims of completed export coverage.

Not all clean-machine install paths have been verified. Friends supply their
own credentials, accounts, signing identities, and service configuration. Do
not pipe this repository to a shell. Inspect every file and command before
use, then verify each component on the target Mac.

## Start with the catalog

- [`STACK.json`](STACK.json) is the machine-readable inventory: installed GUI
  applications, Homebrew and Mac App Store packages, local commands, safe
  operating-system facts, provenance, and the status of every discovery surface.
- [`docs/STACK.md`](docs/STACK.md) explains how the components fit together and
  records operational lessons that a flat inventory cannot express.
- [`STACK_POLICY.json`](STACK_POLICY.json) lists every preference key approved
  for public export. [`settings/`](settings/) contains the resulting values and
  a manifest showing how many unreviewed keys remain private.
- [`COMPONENTS.json`](COMPONENTS.json) maps exported source components and every
  documented exclusion.

The catalog uses five explicit coverage states: `included`,
`safely_summarized`, `excluded`, `unavailable`, and `pending_review`. A missing
component is therefore visible as a decision or gap rather than silently
disappearing.

## Privacy boundary

The public export intentionally omits School, Shortcut source, private memory,
third-party patches, browser and communication history, personal files,
credentials, license values, device identifiers, and runtime state. Preference
files are never copied wholesale. A setting is published only when its domain,
key, value type, and allowed value range have been reviewed. Unknown keys are
counted but not named or copied.

The exported Codex material is a reference template. Replace
`/Users/YOUR_USERNAME` only after reviewing the surrounding command or file.

The phishing-header skill and its API reference are included in full. Three
documented placeholder authorization-header examples receive exact
`gitleaks:allow` annotations so the examples remain readable without treating
them as credentials. The synthetic-secret memory-redaction fixture and the
private-only `personal-repo-sync` synchronizer remain excluded; the immutable
snapshot absence of NutrientTracker `GeneratedData.swift` is also recorded.

`SOURCE_ATTESTATION.json` records the exact private source SHA used to build
this candidate without linking the private repository. Component-level
verification status and path-level exclusion reasons are recorded in
`COMPONENTS.json` and `COMPONENTS.md`.

## Review before restoring

1. Read this file, `SECURITY.md`, `CONTRIBUTING.md`, and
   `docs/PUBLIC_TOOLKIT.md`.
2. Read the component source and its local README before running any command.
3. Supply credentials through your own secure mechanism; never commit them.
4. Build or restore one component at a time and retain the verification output.

The toolkit is deliberately source-first: it does not execute component code,
install LaunchAgents, publish a repository, or make network requests during
export.

## Updates

Public updates are deliberate and on demand. The exporter builds from an
immutable private snapshot, generates the catalog and settings manifests,
performs fail-closed privacy checks, runs a second secret scan, and publishes
only when the complete candidate passes review. No scheduled job publishes this
repository unattended.
