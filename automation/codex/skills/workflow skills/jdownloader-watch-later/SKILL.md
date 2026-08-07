---
name: jdownloader-watch-later
description: Use when Ivo asks to download, add, sync, automate, troubleshoot, or inspect YouTube Watch Later or another YouTube playlist in JDownloader. Trigger on “download my AI playlist,” named YouTube playlists, Watch Later, LinkGrabber, Click'n'Load, Folder Watch, browser-cookie access, duplicate-safe playlist submission, or quitting JDownloader after downloads finish.
---

# JDownloader YouTube Playlists

Use the bundled scripts for the workflow. Do not spend agent tokens reproducing deterministic playlist enumeration, sent-state comparison, JDownloader configuration, submission, or completion monitoring.

## Required result

When Ivo says to download a playlist, the default contract is:

1. Enumerate the playlist’s video URLs.
2. Submit the unsent URLs to JDownloader.
3. Start the downloads automatically.
4. Start and verify the completion watcher.
5. Quit JDownloader after download activity finishes and the download directory becomes idle.

This lifecycle is intentional. Preserve it. `--keep-open` is the per-run opt-out. Do not reduce “download” to listing URLs, adding dormant LinkGrabber entries, or leaving JDownloader open without reporting that degradation.

## Run the workflow

AI playlist:

```bash
"/Users/YOUR_USERNAME/.codex/skills/workflow skills/jdownloader-watch-later/scripts/youtube-playlist-to-jdownloader.sh" --playlist ai
```

Watch Later:

```bash
"/Users/YOUR_USERNAME/.codex/skills/workflow skills/jdownloader-watch-later/scripts/watch-later-to-jdownloader.sh"
```

Another playlist accepts a saved alias, playlist ID, or playlist URL:

```bash
"/Users/YOUR_USERNAME/.codex/skills/workflow skills/jdownloader-watch-later/scripts/youtube-playlist-to-jdownloader.sh" --playlist ALIAS_OR_ID_OR_URL
```

Useful deliberate overrides:

- `--all`: resubmit every visible playlist entry.
- `--dry-run`: enumerate and print what would be submitted, but do not change local state or JDownloader and do not launch it. This can still perform network access and, for Watch Later, an authenticated browser-cookie read.
- `--keep-open`: disable quit-on-complete for this run.
- `--no-autostart`: submit without automatically starting downloads.
- `--method cnl|folderwatch`: force Click'n'Load or Folder Watch instead of automatic selection.
- `--browser safari|firefox`: after the normal public attempt, use only that cookie source if authentication is required; an explicit browser selection never falls back to another browser.
- `--no-browser-cookies`: opt out of browser cookies. Watch Later cannot work without authenticated access.

## Authentication behavior

- Public playlists use public yt-dlp access first. Retry with Safari and then Firefox cookies only after a classified authentication or bot barrier.
- Watch Later uses Safari cookies first and Firefox second.
- Read existing local browser cookies automatically when required. Do not ask for separate cookie permission.
- Keep cookie values local and secret. Never print, persist, export, or send raw cookies to another service.
- Chrome cookie extraction is retired for this workflow. Do not recommend it.
- An explicit `--browser` failure must not silently switch browsers.

The Python enumerator returns structured attempts, degradation reasons, repair actions, and redacted diagnostics. The shell entrypoints remain the operator-facing commands.

## Submission and lifecycle behavior

- Prefer Click'n'Load at `127.0.0.1:9666`. In automatic mode, launch JDownloader hidden and wait for Click'n'Load before falling back to Folder Watch.
- Preserve Folder Watch as the operational fallback at `/Applications/JDownloader 2/cfg/folderwatch`.
- Configure JDownloader’s LinkGrabber auto-confirm and autostart settings when autostart is requested.
- Preserve the trusted Click'n'Load sources used by these scripts.
- Commit sent-state only after JDownloader accepted the Click'n'Load request or the Folder Watch job was written successfully.
- Start the quit watcher only after successful submission. Require the nonce-bound readiness record before claiming the full workflow started.
- Launch the watcher as a nonce-scoped, one-shot user launchd job so it survives the submitting shell; require automatic job deregistration after exit.
- The watcher must observe post-submission download activity before quitting. A run with no observed activity intentionally leaves JDownloader open.
- If configuration changed while JDownloader was already running, report that a restart may be required.

Successful link submission plus watcher startup failure is partial success, not total failure: the scripts keep committed sent-state, return exit code `3`, and tell Ivo to quit JDownloader manually. Do not hide or relabel that result as complete.

## State and destinations

- AI alias: `ai -> PLEzb2QIVWIsT9YAOZm-dWAizqQEsQ68Tw`
- Alias map: `/Users/YOUR_USERNAME/.local/state/jdownloader-watch-later/playlists.json`
- Private state: `/Users/YOUR_USERNAME/.local/state/jdownloader-watch-later/` with directory mode `0700` and state/readiness files mode `0600`.
- Final media: `/Users/YOUR_USERNAME/Files/YouTube`
- JDownloader home: `/Applications/JDownloader 2`
- Watcher log: `/Users/YOUR_USERNAME/.memory/logs/jdownloader-watch-later/quit-on-complete.log`

Media downloads are workflow outputs, not user-facing documents. Do not redirect them to Downloads. Never put scratch files, readiness records, markers, raw evidence, or cookie material in the media folder or Downloads.

The named-playlist script preserves stale-state recovery: if every URL is marked sent but no downloaded media exists below the download root, it resubmits all playlist URLs.

## Failure handling

Never silently abandon an expected path.

- Enumeration failure: show the structured error code, attempted routes, and exact repair action.
- Click'n'Load unavailable in automatic mode: launch JDownloader, retry, then use Folder Watch and disclose the route change.
- Forced Click'n'Load unavailable: stop with an actionable error; do not silently use Folder Watch.
- Browser-cookie failure: diagnose Safari first, then Firefox when automatic fallback is allowed. Report TCC/database/authentication failures and the repair step.
- Watcher missing or unready: preserve the successful submission, return partial status, and tell Ivo to quit JDownloader manually.
- Downloads do not start: inspect auto-confirm/autostart settings and whether JDownloader needs a restart.
- JDownloader does not quit: inspect the watcher log. It will not quit unless it observed download activity and then an idle period.

## Validation after edits

Run the isolated regression suite and the standard skill validator:

```bash
"/Users/YOUR_USERNAME/.codex/skills/workflow skills/jdownloader-watch-later/scripts/selftest.py"
python3 "/Users/YOUR_USERNAME/.codex/skills/.system/skill-creator/scripts/quick_validate.py" "/Users/YOUR_USERNAME/.codex/skills/workflow skills/jdownloader-watch-later"
```

Do not validate by submitting Ivo’s real playlist unless he explicitly asks to start a download now.
