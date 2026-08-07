# Ivo's macOS Source & Restoration Toolkit

This repository is a reviewable source and restoration toolkit for macOS. It
contains Ivo-owned application source, small automations, and reference
material that friends can inspect and adapt. It is not an installer and does
not promise a turnkey clean-machine setup.

Not all clean-machine install paths have been verified. Friends supply their
own credentials, accounts, signing identities, and service configuration. Do
not pipe this repository to a shell. Inspect every file and command before
use, then verify each component on the target Mac.

The public export intentionally omits School, Shortcuts, private memory,
third-party patches, runtime state, credentials, and generated/private
inventory. The exported Codex material is a reference template; replace the
placeholder home path with the local home path only after review.

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

## Start here

[`docs/STACK.md`](docs/STACK.md) is the map of the whole machine — every
application, scheduled job, CLI, backup mechanism, and system customization,
plus a landmine section recording the failures that already cost time. Read it
first if you want to understand how the pieces relate before reading any one
component. It is generated from the live machine's tool registry and LaunchAgent
directory, so it describes what actually runs rather than what was intended.

## Review before restoring

1. Read this file, `SECURITY.md`, `CONTRIBUTING.md`, and
   `docs/PUBLIC_TOOLKIT.md`.
2. Read the component source and its local README before running any command.
3. Supply credentials through your own secure mechanism; never commit them.
4. Build or restore one component at a time and retain the verification output.

The toolkit is deliberately source-first: it does not execute component code,
install LaunchAgents, publish a repository, or make network requests during
export.
