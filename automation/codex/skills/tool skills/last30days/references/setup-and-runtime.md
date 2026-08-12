# Last30Days setup and runtime

## Contents

- [Runtime Preflight](#runtime-preflight)
- [Configuration](#configuration)
- [Step 0: First-Run Setup Wizard](#step-0-first-run-setup-wizard)

# last30days v3.8.3: Research Any Topic from the Last 30 Days

> **Permissions overview:** Reads public web/platform data and optionally saves raw research briefings to `LAST30DAYS_MEMORY_DIR` (defaults to `$HOME/.local/state/last30days/reports`). X/Twitter search uses optional user-provided tokens (AUTH_TOKEN/CT0 env vars). Bluesky search uses optional app password (BSKY_HANDLE/BSKY_APP_PASSWORD env vars - create at bsky.app/settings/app-passwords). Explicit user-facing HTML exports are saved under `/Users/YOUR_USERNAME/Downloads` unless the user requests another path. All credential usage and data writes are documented in the [Security & Permissions](#security--permissions) section.

Research ANY topic across Reddit, X, YouTube, and other sources. Surface what people are actually discussing, recommending, betting on, and debating right now.

## Runtime Preflight

Before running any `last30days.py` command in this skill, resolve a Python 3.12+ interpreter once and keep it in `LAST30DAYS_PYTHON`:

```bash
try_last30days_python() {
  candidate="$1"
  [ -n "$candidate" ] || return 1
  if [ -x "$candidate" ]; then
    :
  elif command -v "$candidate" >/dev/null 2>&1; then
    :
  else
    return 1
  fi
  "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' || return 1
  LAST30DAYS_PYTHON="$candidate"
  return 0
}

windows_path_to_unix() {
  path="$1"
  [ -n "$path" ] || return 1
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$path"
  else
    printf '%s\n' "$path"
  fi
}

if [ -z "${LAST30DAYS_PYTHON:-}" ]; then
  while IFS= read -r windows_python_root; do
    [ -n "$windows_python_root" ] && [ -d "$windows_python_root" ] || continue
    while IFS= read -r py; do
      try_last30days_python "$py" && break 2
    done <<EOF_PYTHON_CANDIDATES
$(find "$windows_python_root" -maxdepth 2 -type f -iname python.exe 2>/dev/null | sort -r)
EOF_PYTHON_CANDIDATES
  done <<EOF_WINDOWS_PYTHON_ROOTS
$([ -n "${LOCALAPPDATA:-}" ] && printf '%s\n' "$(windows_path_to_unix "$LOCALAPPDATA")/Programs/Python")
$([ -n "${ProgramFiles:-}" ] && windows_path_to_unix "$ProgramFiles")
$([ -n "${PROGRAMFILES:-}" ] && windows_path_to_unix "$PROGRAMFILES")
$(program_files_x86="$(printenv 'ProgramFiles(x86)' 2>/dev/null || true)"; [ -n "$program_files_x86" ] && windows_path_to_unix "$program_files_x86")
EOF_WINDOWS_PYTHON_ROOTS
fi

if [ -z "${LAST30DAYS_PYTHON:-}" ]; then
  for py in python3.14 python3.13 python3.12 python3 python; do
    try_last30days_python "$py" && break
  done
fi

if [ -z "${LAST30DAYS_PYTHON:-}" ]; then
  echo "ERROR: last30days v3 requires Python 3.12+. Install Python 3.12+ or set LAST30DAYS_PYTHON to a supported interpreter." >&2
  exit 1
fi

"${LAST30DAYS_PYTHON}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' || {
  echo "ERROR: LAST30DAYS_PYTHON must point to Python 3.12+." >&2
  exit 1
}

LAST30DAYS_MEMORY_DIR="${LAST30DAYS_MEMORY_DIR:-$HOME/.local/state/last30days/reports}"
mkdir -p "$LAST30DAYS_MEMORY_DIR"
```

**PYTHON VERSION GATE — when the Runtime Preflight Bash block above exits with a Python version error:**

If the preflight script emits `ERROR: last30days v3 requires Python 3.12+` (or `LAST30DAYS_PYTHON must point to Python 3.12+`) and exits, you MUST:

1. Display this message to the user:
   > "The last30days engine needs Python 3.12+. Your system has an older version. Install it with one command:
   > - **Mac:** `brew install python@3.12`
   > - **Windows:** `winget install Python.Python.3.12`
   > - **Linux:** `sudo apt install python3.12` (or `pyenv install 3.12`)
   >
   > Then re-run `/last30days <your topic>` and the setup wizard will configure everything automatically."
2. **Stop.** Do not attempt research. Do not fall back to WebSearch-only synthesis.

WebSearch-only synthesis is not equivalent to running the engine — it misses Reddit community data, X/Twitter timelines, YouTube transcripts, TikTok, and Polymarket. Presenting it without disclosure misleads the user about what was actually searched. Verify engine execution from its exit status and hidden report rather than a visible footer.

**Native-search signal (web coverage).** If you (the hosting model) have your own web-search tool available, export `LAST30DAYS_NATIVE_SEARCH=1` in the same shell before invoking the engine:

```bash
export LAST30DAYS_NATIVE_SEARCH=1   # ONLY when you have a native web-search tool
```

Your host search is better than the engine's keyless web fallback, so this tells the engine to skip that fallback and leave general web to you (you already run web-search supplements in Step 2). If you have NO web-search tool in the agent session, do **not** set this: the engine's keyless web floor supplies general-web coverage automatically. The rule is capability-based, not host-name-based — set it only when you genuinely have a better search, never to suppress the floor on a host that has nothing else.

## Configuration

Set `LAST30DAYS_MEMORY_DIR` before invoking the skill to choose where raw research files are saved. If it is not set, the skill defaults to `$HOME/.local/state/last30days/reports`. Raw `.md` research artifacts are backend state, not front-end deliverables, so keep them out of visible document destinations. Explicit user-facing HTML exports use `/Users/YOUR_USERNAME/Downloads` unless the user requests another path.

The engine reads `LAST30DAYS_MEMORY_DIR` from either the process env or `~/.config/last30days/.env`, so direct CLI invocations (`python3 scripts/last30days.py ...`) without `--save-dir` will still save when the env var is set. Mirrors the `LAST30DAYS_STORE` env-or-flag convention. Explicit `--save-dir` always wins.

## Step 0: First-Run Setup Wizard

**CRITICAL: ALWAYS execute Step 0 BEFORE Step 1, even when the user provided a topic.** If the user typed `/last30days Mercer Island`, you MUST run the wizard BEFORE any research. The topic is preserved - research runs immediately after the wizard completes. Do NOT skip the wizard because a topic was provided. It takes about 30 seconds and only runs once, ever.

**You are the conversational driver.** The Python setup script does mechanical work (local cookie reads, tool installs, and the GitHub device-auth flow) but cannot present choices. Local cookie reads use Ivo's standing authorization and need no prompt. Keep conversational approval for optional package installation, external signup/device authorization, and paid-source opt-ins. Surface every failed setup path and repair action.

**First-run detection (silent, no commands, no output to user):**
- If `SETUP_COMPLETE=true` is available from process env, project config (`.claude/last30days.env`), global config (`~/.config/last30days/.env`), or the setup check reports configured credentials, skip Step 0 entirely and go to Step 1 (CRITICAL: Parse User Intent below). Do NOT announce that setup is complete. The user does not need a status message on every run.
- Do NOT treat the absence of `~/.config/last30days/.env` alone as a first run. Credentials may live in process env, project config, macOS Keychain (`last30days-<KEY>`), pass(1), or host-provided auth.
- If no setup marker or credential source is present, this is a first run.

**Named onboarding contracts:**
- *(2026-06-22, silent-wizard regression - Fredy Montero run):* a prior version ran `setup` without surfacing the macOS Full Disk Access fix or offering the ScrapeCreators signup. Cookie reads are now covered by Ivo's standing authorization, but setup failures and optional external signup choices must still be visible.
- *(2026-06-22, NUX restoration):* keep the guided first-run flow for setup choice, ScrapeCreators, source opt-in, and the first-topic picker. A separate cookie-consent modal is intentionally removed; do not restore it.

**Platform split - run exactly ONE branch:**
- **If you HAVE WebSearch and AskUserQuestion (Claude Code):** run the **Claude Code Modal Flow** immediately below.
- **If you do NOT (OpenClaw, Codex, Cursor, Gemini CLI, raw CLI):** run the **Non-Modal Prose Flow** further down. It does the same work conversationally, without modals.

---

### Claude Code Modal Flow

**Follow these steps IN ORDER. Do NOT skip ahead to research. The sequence is: (1) welcome text → (2) setup modal → (3) run setup if chosen → (4) ScrapeCreators offer modal → (5) source opt-in modal → (6) first-topic picker. Start at step 1.**

**Step 1 - Welcome.** Display this welcome text ONCE as a normal message (not blockquoted).

Welcome to /last30days!

I research any topic across Reddit, X, YouTube, and more - synthesizing what people are actually saying right now.

Auto setup gives you the core sources free in about 30 seconds:
- X/Twitter - reads your browser cookies to authenticate (read live each run, never saved to disk).
- Reddit with comments - public JSON, no API key needed.
- YouTube search + transcripts - installs yt-dlp (open source, 190K+ GitHub stars).
- Digg - trending news, GitHub stars, and pipeline feeds - installs the free, keyless Digg CLI.
- arXiv (📄) + Techmeme (📰) - research papers and tech-news headlines - install free, keyless Printing Press CLIs and run on any topic (arXiv is relevance + recency gated to research topics).
- Trustpilot (⭐) - brand/company review sentiment - opt-in (add `trustpilot` to `INCLUDE_SOURCES`), off by default because it can do a one-time ~10s headless browser cookie step on first company lookup. Install with `npx -y @mvanhorn/printing-press-library@0.1.16 install trustpilot --cli-only`.
- Hacker News + Polymarket + GitHub (auto-on if the `gh` CLI is installed) - always on, zero config.

Want TikTok and Instagram too? ScrapeCreators adds those (10,000 free calls, scrapecreators.com). No kickbacks, no affiliation.

**Step 2 - Setup choice.** Then IMMEDIATELY call AskUserQuestion with ONLY this question and these options (do not repeat the welcome text inside the modal):

Question: "How would you like to set up?"
Options:
- "Auto setup (~30 seconds) - scans browser cookies for X + installs yt-dlp (YouTube) and the Digg CLI"
- "Manual setup - show me what to configure"
- "Skip for now - Reddit (with comments), HN, Polymarket, GitHub (if `gh` installed), Web"

**Step 3 - Run setup based on the choice.**

**If the user picks Skip for now:** write `SETUP_COMPLETE=true` to `~/.config/last30days/.env` (append-only; run `mkdir -p ~/.config/last30days && touch ~/.config/last30days/.env` first if the file does not exist) so the wizard does NOT re-fire on every subsequent run, then skip straight to Step 6 (the topic picker). Do not run any `setup` command - the always-on sources (Reddit, HN, Polymarket, GitHub, Web) need no setup.

**If the user picks Auto setup:**

Run `python3 skills/last30days/scripts/last30days.py setup` directly. It automatically scans Safari and then Firefox for X cookies, reads values only in memory, and never saves raw cookie values. Chromium browsers remain excluded unless `FROM_BROWSER=auto` or a named Chromium browser was explicitly configured, because they may trigger a macOS Keychain prompt. The same run best-effort installs yt-dlp (YouTube) and the free, keyless Digg CLI (`digg-pp-cli` via `@mvanhorn/printing-press-library install digg --cli-only`; Digg activates only when the binary is on the **agent subprocess PATH**, typically `$HOME/.local/bin`; setup reports honestly if installed off-PATH; recommend-only if `npx` is unavailable). Show what was found and installed, including which browser supplied cookies and whether Digg landed on PATH. `--no-browser-cookies` or `FROM_BROWSER=off` remains the explicit opt-out.

**macOS Full Disk Access remediation.** After the `setup` run, inspect its stderr. If it contains `Permission denied reading Cookies.binarycookies` and the platform is macOS, the OS blocked the read - surface the fix instead of swallowing it: `macOS blocked the cookie read. To enable X/Twitter: System Settings > Privacy & Security > Full Disk Access > enable your terminal (or the Claude app), then I can retry.` Offer ONE retry of the `setup` command. If the user skips, continue.

**Step 4: ScrapeCreators offer (every first run).** Show this as plain text, then a modal:

ScrapeCreators adds TikTok and Instagram - 10,000 free calls, no credit card. Your key also powers YouTube comments, a YouTube transcript fallback (used only when yt-dlp gets rate-limited), and a Reddit backup (if public Reddit gets rate-limited). (We don't get a cut.)

Before the modal, run `which gh` via Bash silently; store as gh_available.

**Call AskUserQuestion:**
Question: "Want to add TikTok, Instagram, and the ScrapeCreators backups? (We don't get a cut.)"
Options:
- "ScrapeCreators via GitHub (fastest, recommended)" - If gh_available, description: "Registers via GitHub CLI in ~2 seconds - no browser." If NOT gh_available, description: "Copies a one-time code to your clipboard and opens GitHub to authorize." After selection: if gh_available, display "Registering via GitHub CLI..."; if not, display "I'll copy a one-time code to your clipboard and open GitHub. When prompted for a device code, just paste (Cmd+V / Ctrl+V)." Then run `python3 skills/last30days/scripts/last30days.py setup --github` with a 5-minute timeout. Parse the JSON. On `status == "success"` the engine persists the key automatically and returns `"persisted": true` with a MASKED `api_key` (the raw key never appears - do not ask for or echo it); confirm "You're in! 10,000 free calls. TikTok, Instagram, YouTube comments, and the Reddit/YouTube backups are now active." On `status == "success"` but `"persisted": false` (key write failed, e.g. a permissions error), do NOT claim sources are active - tell the user the signup worked but saving the key failed, and have them add `SCRAPECREATORS_API_KEY=<key>` to `~/.config/last30days/.env` manually (the raw key is masked in output, so re-run `setup --github` or retrieve it from scrapecreators.com to get the value). On `status` `timeout`/`error`, show "GitHub auth didn't complete - no worries, sign up at scrapecreators.com or try again later," then offer the web option.
- "Open scrapecreators.com (Google sign-in)" - run `open https://scrapecreators.com` via Bash, then ask them to paste the API key. Write `SCRAPECREATORS_API_KEY={key}` to `~/.config/last30days/.env`.
- "I have a key" - accept the key, write to `.env`.
- "Skip for now" - proceed without ScrapeCreators.

**Step 5: Source opt-in (only if a ScrapeCreators key was saved, not if skipped).** Plain text then modal:

Your ScrapeCreators key powers TikTok, Instagram, and YouTube comments. Want TikTok and Instagram on for every run? (Each adds one ScrapeCreators call per search.)

**Call AskUserQuestion:**
Question: "Which ScrapeCreators sources do you want on?"
Options:
- "TikTok + Instagram (recommended)" - append `INCLUDE_SOURCES=tiktok,instagram` to `~/.config/last30days/.env`. Confirm: "TikTok and Instagram are on, plus the Reddit/YouTube backups if the free sources get rate-limited."
- "Just the basics - let's run my first search" - don't write the flag. Confirm: "Got it. ScrapeCreators will still serve as the Reddit and YouTube backups. You can add sources to `INCLUDE_SOURCES` in your `.env` anytime."

**Step 6: First-topic picker.** Once `SETUP_COMPLETE=true` is written, **call AskUserQuestion:**
Question: "What do you want to research first?"
Options:
- "Claude Code vs Codex" - tech comparison
- "Sam Altman" - person in the news
- "Warriors Basketball" - sports
- "AI Legal Prompting Techniques" - niche/professional
- "Type my own topic"

If the user picks an example, run research with it. If "Type my own", ask what they want. **If the user already supplied a topic with the command (e.g. `/last30days Mercer Island`), SKIP this picker and use their topic directly.**

**END OF FIRST-RUN WIZARD.** Everything in the Modal Flow ONLY runs on first run. If `SETUP_COMPLETE=true` exists, skip ALL of it - no welcome, no modals, no topic picker - and go straight to research (Parse User Intent).

**If the user picked Manual setup** at Step 2, follow the **Manual Setup Guide** below instead of the Auto branch (the guide writes `SETUP_COMPLETE=true` itself), then continue to Step 6.

---

### Non-Modal Prose Flow

For hosts without interactive modal prompts (OpenClaw, Codex, Cursor, Gemini CLI, raw CLI). Same work, done conversationally. Run in order; wait where it says to wait.

**1. Welcome.** One short branded line, e.g.: `Welcome to /last30days - let me get you set up (about 30 seconds).`

**2. Permission preflight.** Run `${LAST30DAYS_PYTHON:-python3} "${SKILL_DIR}/scripts/last30days.py" --preflight` using the directory of the `SKILL.md` you loaded, then summarize the human-readable result before setup: config source, project config trust/ignore state, planned browser-cookie mode, planned writes, optional commands, and active/ignored endpoint overrides. This is safe: it does not read browser-cookie values, does not write setup/config/report files, and does not run research. For Codex desktop and other folder-mode hosts, if hidden `.claude/last30days.env` project config is shown as ignored, tell the user it remains ignored unless `LAST30DAYS_TRUST_PROJECT_CONFIG=1` is set from the process environment or global config. Do not block normal research on missing optional commands; describe them as optional coverage.

**3. Automatic local authentication.** Run `python3 skills/last30days/scripts/last30days.py setup` without asking a separate cookie question. It tries Safari then Firefox, keeps cookie values in memory, and never writes them to research artifacts. Chromium remains opt-in through `FROM_BROWSER=auto` or an explicitly named browser. Use `--no-browser-cookies` or `FROM_BROWSER=off` only when Ivo explicitly opts out.

**4. Full Disk Access remediation (macOS only).** After `setup`, inspect stderr. If it contains `Permission denied reading Cookies.binarycookies` on macOS, surface: `macOS blocked the cookie read. To enable X/Twitter: System Settings > Privacy & Security > Full Disk Access > enable your terminal (or the Claude app), then I can retry.` Offer ONE retry. If skipped, continue.

**5. ScrapeCreators signup offer (every first run, consent BEFORE launching the browser).** Explain it grants 10,000 free calls that unlock TikTok, Instagram, YouTube comments, plus a Reddit backup and a YouTube transcript fallback, and that it opens a GitHub authorization page. Ask, e.g.: `Want to unlock TikTok, Instagram, and more? I can sign you up for ScrapeCreators with GitHub (10,000 free calls) - it opens a browser to authorize. (yes / no)` **Wait for the answer.**
   - On **yes** → run `python3 skills/last30days/scripts/last30days.py setup --github`. A browser window opens; the user authorizes with the code shown. On success the engine persists the key automatically and returns `"persisted": true` with a MASKED `api_key` (never ask for or echo the raw key). Confirm the paid sources are active.
   - On **success but `"persisted": false`** (auth completed yet the key write failed) → do NOT claim sources are active. Tell the user signup worked but saving failed, and have them add `SCRAPECREATORS_API_KEY=<key>` to `~/.config/last30days/.env` manually (the raw key is masked in output, so re-run `setup --github` or retrieve it from scrapecreators.com to get the value).
   - On **timeout / denied** → tell the user it didn't complete and offer to retry or skip.
   - On **no** → note they can run it later by asking to set up ScrapeCreators, then continue.

**6. Complete.** Once `SETUP_COMPLETE=true` is written, briefly confirm which sources are now active (read the `setup --github` JSON `persisted` field, re-run `--preflight` for a human permission summary, or re-run safe `--diagnose` for JSON) and proceed to research. For Codex desktop, Cursor, Gemini CLI, and raw folder-mode hosts, hidden `.claude/last30days.env` project config is ignored unless `LAST30DAYS_TRUST_PROJECT_CONFIG=1` is set from the process environment or global config; do not tell the user a project file is active unless diagnose reports it as the config source.

---

### Manual Setup Guide

Shown when a Claude Code user picks "Manual setup", or for anyone who wants to configure by hand. Present as plain text (not blockquoted).

The magic of /last30days is Reddit comments + X posts together - and both are free. Add these to `~/.config/last30days/.env`:

**X/Twitter (pick one - the most important source):**
- Browser cookies are automatic on macOS: Safari first, then Firefox, read live and never saved to disk. Set `FROM_BROWSER=off` to disable them or `FROM_BROWSER=auto` to include installed Chromium browsers.
- `XAI_API_KEY=xxx` - no browser access needed. Get a key at api.x.ai. Best for servers.
- `XQUIK_API_KEY=xxx` - keyless-style X via Xquik.
- `AUTH_TOKEN=xxx` + `CT0=xxx` - paste your X cookies manually (x.com → F12 → Application → Cookies).

**Reddit (free, works out of the box):**
- Public JSON gives threads + top comments with upvote counts. No setup required.
- `SCRAPECREATORS_API_KEY=xxx` - optional backup if public Reddit gets rate-limited.

**YouTube (free, open source):**
- Run `brew install yt-dlp` (or `pip install yt-dlp`) - enables YouTube search + transcripts.
- `SCRAPECREATORS_API_KEY=xxx` - optional server-side transcript fallback, used only when yt-dlp is rate-limited/bot-gated.

**Digg (free, keyless):**
- Run `npx @mvanhorn/printing-press-library install digg --cli-only` - installs the Digg CLI for trending news, GitHub stars, and pipeline feeds. Activates when `digg-pp-cli` is on your PATH (typically `$HOME/.local/bin`).

**GitHub Issues/PRs (free, no key needed):**
- If the `gh` CLI is installed and authed (`brew install gh && gh auth login`), GitHub search is automatic. No API key required.

**Bonus: TikTok, Instagram, YouTube comments (ScrapeCreators):**
- `SCRAPECREATORS_API_KEY=xxx` - 10,000 free calls at scrapecreators.com.
- After adding your key, set `INCLUDE_SOURCES=tiktok,instagram` to turn on the popular ones. (Threads, Pinterest, and LinkedIn are also available via `INCLUDE_SOURCES=threads,pinterest,linkedin` for power users.)

**Other optional sources (add anytime):**
- `PERPLEXITY_API_KEY=xxx` (or `OPENROUTER_API_KEY=xxx`) - AI-synthesized research with citations; set `INCLUDE_SOURCES=perplexity`.
- `BSKY_HANDLE=you.bsky.social` + `BSKY_APP_PASSWORD=xxx` - Bluesky (free app password).
- `BRAVE_API_KEY=xxx` or `EXA_API_KEY=xxx` - web search backends.

**CRITICAL: NEVER overwrite an existing `.env`.** Before writing ANY key:
1. Check if the file exists: `test -f ~/.config/last30days/.env`
2. If it exists, READ it, then APPEND only missing keys with `>>` (double redirect).
3. NEVER use `>` (single redirect) - it destroys existing content.
4. If it doesn't exist: `mkdir -p ~/.config/last30days && touch ~/.config/last30days/.env`

Always add this last line: `SETUP_COMPLETE=true`. Then proceed to research.

The setup wizard's mechanical work lives in a Python module so it runs across all hosts (Claude Code, Codex, Cursor, etc.) while you drive optional external signup choices above. The common-case (already set up) path through this file stays short.

---
