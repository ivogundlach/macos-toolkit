---
name: github-workflow
description: >-
  Use whenever work involves GitHub or a Git remote: creating, cloning,
  importing, archiving, committing, pushing, fetching, pulling, forking, or
  mirroring repositories; inspecting or changing remotes, branches, tags,
  issues, pull requests, releases, Actions, settings, permissions, or
  visibility; publishing completed project work; or deciding whether local
  projects, scripts, skills, and configuration belong on GitHub. Also use for
  the project owner's private source archive source archive. Combine with vibe-coding for code
  changes, peer-review when review is requested or globally required,
  scriptify for recurring deterministic Git mechanics, and
  macos-background-jobs when that mechanic must run unattended.
---

# GitHub Workflow

Manage GitHub as versioned external state. Keep the local project or designated
canonical source authoritative unless repository instructions say otherwise.

## Authority

Classify the intended action before changing state:

- Read-only: inspect status, history, diffs, remotes, repository metadata,
  issues, pull requests, releases, checks, and Actions logs. Proceed when
  relevant to the task.
- Ordinary authorized write: commit or push only when the project owner's current request
  explicitly includes it or repository instructions or canonical project
  memory record concrete prior authorization for that repository and action.
  Never infer permission from a configured remote, earlier unrelated push, or
  convenience.
- Fresh explicit authority required: create a repository; expose anything
  publicly; change visibility, settings, permissions, collaborators, branch
  protection, or default branch; publish or merge a pull request; create or
  delete a release; delete a repository, branch, tag, issue, or remote;
  rewrite history; force-push an existing ref; transfer ownership; or write to
  a third-party repository.

Default a newly authorized personal repository to private when visibility is
unspecified. Do not create a repository merely because a folder lacks Git.

## Tool Route

1. Use local `git` for the working tree, history, branches, commits, and
   transport.
2. Use authenticated `gh` for GitHub-specific metadata and API actions.
3. Use browser control only for read-only inspection. If CLI or API access
   cannot complete an authorized write, stop and report the blocker rather
   than writing through the browser.
4. Never install or depend on a GitHub plugin or MCP server.

Do not print credentials or authentication material. Redact `gh auth` output
and diagnostics.

## Preflight

Before mutation:

1. Read the applicable `AGENTS.md`, repository instructions, nearest project
   memory, and relevant documentation.
2. Inspect `git status --short`, current branch, remotes, upstream tracking,
   recent history, and worktrees. Fetch the intended remote when network state
   matters.
3. Confirm repository ownership and destination. Treat unexpected remotes,
   detached HEAD, unresolved conflicts, and authentication mismatch as
   blockers.
4. Check for concurrent or unattributed changes. Preserve them, do not stage
   them, and do not switch branches, pull, rebase, stash, clean, or reset over
   them.
5. Predeclare the exact files this task may stage. Attribute files from the
   task's actual writes, not from a post-hoc interpretation of `git status`.

## Commit and Push

For an authorized commit and push:

1. Verify the requested result before versioning it.
2. Stage only predeclared paths with explicit pathspecs. Never use broad
   `git add .`, `git add -A`, or `git commit -a` in a dirty or shared tree.
3. Inspect `git diff --cached --name-status` and the full staged diff. Abort if
   the staged set includes anything unattributable or out of scope.
4. Treat explicit-path staging as the primary inclusion boundary. Enforce
   `.gitignore`, a sensitive-filename denylist, and staged-content review as
   defense in depth. Never commit secrets, `.env` files, credentials, private
   keys, cookies, tokens, hidden memory, personal runtime data, build products,
   dependency caches, or generated local state.
5. Run `gitleaks git --staged --redact`. If gitleaks is unavailable, errors,
   or reports a finding, do not push. Gitleaks is corroborating evidence, not
   proof that staged content is safe.
6. Recheck the staged diff and the predeclared files immediately before the
   commit. Abort if either changed after review.
7. Commit with a concise message describing the user-visible or operational
   outcome. Do not mix unrelated changes.
8. Fetch the remote branch again. If an existing remote ref moved from the
   observed base, stop; do not rebase, merge, or force automatically.
9. Push normally. A non-fast-forward rejection is authoritative: stop and
   report it without retrying destructively. For an explicitly authorized new
   branch, use an empty-expectation lease
   (`--force-with-lease=refs/heads/BRANCH:`) solely to ensure the remote ref
   remains absent; never use that exception to update an existing ref.
10. Verify the remote ref SHA through `git ls-remote` or `gh api` and compare
    it with the intended local commit. If verification mismatches, report and
    stop; do not rewrite or revert remote history automatically.

Report the commit, destination repository and branch, checks performed, and
any unrelated local changes left untouched.

## Repository Selection

- Keep each active project in its established repository when one exists.
- Prefer a private repository for personal source, automation, configuration,
  and unpublished apps.
- Keep independent projects separate when they have their own lifecycle,
  history, release process, or collaborators.
- Use the established private source archive archive for the project owner-owned source that
  otherwise exists only locally and is covered by its repository map and sync
  script.
- Do not commit large binaries, build artifacts, dependency directories,
  caches, backups, logs, databases, or personal content merely to make a
  repository "complete." Preserve reproducible source, configuration examples,
  build/install scripts, and concise restoration documentation.
- For third-party checkouts with local modifications, never push to the
  upstream owner's remote. Use an explicitly approved private mirror or fork
  and preserve upstream attribution and history.

## Source Archive

Keep local projects and canonical source authoritative, and use a disposable
clone for deterministic source snapshots.  The snapshot must have an explicit
manifest, preserve unrelated dirty paths, and remain private unless a separate
request authorizes publication.  Never copy credentials, private memory,
personal runtime data, caches, build products, or generated bundles into an
archive.  Generated mirrors are not canonical source and should be excluded.

## Pulls, Pull Requests, Releases, and Automation

- Use a deterministic recurring snapshot job for approved source archives.
  It must use a disposable clone and must not stage, clean, reset, or commit a
  shared control checkout. Use the project's scripting and background-job
  workflows when changing that mechanic or its scheduler.
- Unattended source archive runs must stop when a snapshot would delete more
  than 25 paths or more than 20% of the prior tracked snapshot. Proceed only
  through the worker's reviewed-large-deletion override after the exact
  deletion manifest has received the review required by global instructions.
- Recurring authority is limited to source-snapshot commits and normal pushes
  to the existing private `the configured destination/source archive` `main` branch. It never
  authorizes a new repository, branch, release, pull request, visibility or
  permission change, history rewrite, or third-party write.
- Do not pull into a dirty tree. Fetch and inspect first; integrate only when
  authorized and safe.
- Creating a local branch or drafting PR text does not authorize publishing a
  pull request. Publishing or merging requires explicit authority.
- Creating release notes or artifacts does not authorize a GitHub release.
- Treat workflow-file changes as code and as permission-sensitive
  infrastructure. Inspect requested permissions, secret use, event triggers,
  and third-party action pinning; apply globally required review.
- Never enable Actions, install apps, add deploy keys, create tokens, or change
  repository/account settings without explicit authority.

## Failure Handling

Stop without destructive cleanup when authentication fails, the remote
diverges, secret scanning fails, the staged set changes, the destination is
uncertain, or concurrent work overlaps. Preserve evidence, disclose the exact
blocker, and leave unrelated work untouched.
