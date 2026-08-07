# Contributing

Contributions should remain small, reviewable, and source-first. Explain the
component, the macOS version or toolchain used, the exact verification command,
and any limitation that remains unverified.

Do not add credentials, personal memory, runtime state, generated bundles,
private inventory, School or Shortcut exports, third-party patches, or hidden
installer behavior. Keep component notices with the component and do not claim
third-party ownership. Preserve the documented omission of the synthetic
secret-redaction fixture, private-only `personal-repo-sync`, and the absent
NutrientTracker `GeneratedData.swift` path; do not recreate them with private
content.

Inspect scripts before use. Do not pipe commands from the repository directly
to a shell. A pull request is not evidence that a clean-machine install works;
include reproducible local verification instead.
