# Security

Treat this repository as source to review, not as a trusted installer. Read
scripts before running them, use a disposable checkout when possible, and
verify paths, permissions, network access, and LaunchAgent behavior on the
target Mac.

Friends must provide their own credentials and service accounts. Keep tokens,
webhooks, cookies, signing keys, environment files, and personal data outside
the checkout. Never put a real secret in an issue, pull request, test fixture,
or example file.

The export process removes private memory, runtime state, credentials,
third-party patches, School, Shortcuts, and generated evidence. The phishing
header skill is retained with three exact scanner-allow annotations on
documented placeholder authorization headers; those annotations are not an
authorization to add real credentials. The synthetic-secret memory fixture and
private-only synchronizer are excluded and listed with reasons in
`COMPONENTS.md`. If a secret or private identifier appears in an exported source
file, stop using that file and report the path without including the secret
value.

For a suspected vulnerability, make a local report to the project owner with
the component name, affected path, reproduction summary, and a proposed safe
fix. Do not publish sensitive details until they have been reviewed.
