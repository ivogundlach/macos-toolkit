# Go-Live Checklist — Market Dashboard

STATUS 2026-07-01: LaunchAgents are LOADED (Ivo moved the start up). `delivery.go_live_not_before
= 2026-07-05` gates firing; first automatic debrief = Sunday 2026-07-05 17:00, prepping Monday
2026-07-06. Regime + YouTube verified live 2026-07-01. Remaining before Sunday: item 1 (X login,
Ivo-interactive). TradingView/Discord stay disabled until access arrives — the pipeline runs
without them (required coverage = x_tier1 + regime).

DELIVERY 2026-07-01/03: NO EMAILS. The debrief and every alert (ready/degraded/entry/exit/
failed/missed) live ONLY in Market.app — full debrief on the Overview card, alerts as native
push notifications. The app does NOT need to be open: after each run the pipeline invokes
`Market --notify-drain` (headless: claim → post → ack → exit). VERIFIED WORKING 2026-07-03.
The GUI also polls every 45s while open.
Notification permission gotcha (solved 2026-07-03): macOS registers self-signed local apps
with notifications OFF and NEVER shows a prompt (UNErrorDomain Code=1 while notDetermined).
Fix = enable Market manually in System Settings → Notifications (Ivo did). The app is signed
with the stable "Ivo Market Dev" identity (~/Projects/Market/state/signing/, wired into
packaging/build-app.sh) so rebuilds do NOT reset the toggle — never fall back to ad-hoc.
If delivery ever breaks, deliver_via_app() falls back to terminal-notifier/osascript
automatically; rows are never lost (outbox + 120s lease).

## 1. X / Twitter → Playwright (only method; Firecrawl removed 2026-06-13)
- NO SETUP NEEDED as long as Ivo stays logged into x.com in Safari. The adapter reads Safari's
  live x.com cookies at the start of EVERY run and injects them (`_safari_x_cookies`), so the
  scrape is always logged in with fresh posts. Why: X rotates/revokes `auth_token` per browser
  fingerprint, so a session saved in the Playwright profile goes dead between runs — verified
  2026-07-03 (import verified logged-in, next run logged OUT, saw only months-old "top posts"
  and wrongly looked like the accounts were dormant; they post hourly). Reading Safari fresh
  each run sidesteps both that and X's login rate limit entirely.
- One-time verify: `PLAYWRIGHT_BROWSERS_PATH=~/Library/Caches/ms-playwright venv/bin/python adapters/x_playwright.py`
  → expect "N new" per handle. If it logs "0 kept … likely logged out", just open Safari and
  log into x.com again; nothing else to configure.
- Fallbacks if Safari isn't usable: `--import-safari` (one-shot copy into the profile),
  `--import-cookies` (manual paste), or `--login` (interactive; wait ≥24h if rate-limited).
- [ ] Test: `venv/bin/python adapters/x_playwright.py` → check `out/logs` for "N new" per handle.
- Session persists in `state/x_profile/` (0700). Refresh login when the adapter logs the
  "session likely logged out" warning (see below) or keeps skipping everything.
- LOGGED-OUT HAZARD (2026-07-01): logged-out X serves OLD viral "top posts" without usable
  `<time datetime>` elements — NOT zero posts as originally assumed. The adapter now skips any
  post with no parseable timestamp or older than 14 days and warns loudly instead of ingesting;
  a 245-event poisoned batch from the logged-out scrape was purged the same day.
- (Lightpanda was tested and rejected for X: renders "Something went wrong", 0 posts.)
- Last30Days is installed globally for topic/person/company research across X/Reddit/HN/YouTube/GitHub, but it is not the Market ingestion method. Use it as a research overlay or fallback context check, not as a replacement for the exact profile-ingest adapter. Local wrapper: `last30days --preflight`; raw outputs default to hidden state at `/Users/YOUR_USERNAME/.local/state/last30days/reports`.

## 2. TradingView (rank 2)
- [ ] In TradingView, on each alert tick **"Send plain text"** with alternative email
      `you@example.com` (account email is you.backup@example.com; gws is main-only).
- [ ] Create the inbox-skip filter (one of):
      - Manual (Gmail → Settings → Filters): from `noreply@tradingview.com` →
        Skip Inbox + Apply label `tradingview-alerts`. OR
      - Scripted: re-auth gws with the settings scope, then create via API:
        `gws auth login --scopes ...,https://www.googleapis.com/auth/gmail.settings.basic`
- [ ] Set `sources.tradingview.enabled = true` in config.json.
- Label `tradingview-alerts` (Label_9) + adapter already verified 2026-06-13.

## 3. Discord (rank 1, highest trust)
- [ ] Install DiscordChatExporter CLI (read-only export tool).
- [ ] Put user token in `~/Projects/Market/secrets.env` as `DISCORD_TOKEN` (chmod 600).
- [ ] Add the premium alert channel IDs to `sources.discord.channels`; set `enabled = true`.
- [ ] Replace `adapters/discord_stub.py` with the exporter wrapper (see its docstring):
      export channel JSON since last watermark → `store.insert_event(source="discord", rank=1, ...)`.

## 4. Knowledge base review
- [ ] Read `knowledge/indicator-suite.md` (Arch/Helix rules extracted from Startup.io DB);
      edit/approve before relying on it in production synthesis.

## 5. Schedule (the actual go-live)
- [ ] Confirm Time Machine has an off-disk destination covering `~/Projects/Market` (currently local-only).
- [x] `bash launchd/install.sh` → UPDATED 2026-07-17; one signed `com.ivo.market.refresh`
      LaunchAgent dispatches ingest (08:00), debrief (16:15, fluid gate), and watchdog (17:10),
      with per-stage success/failure state and Tool Status Dashboard monitoring.
- [x] First scheduled debrief: Sunday 2026-07-05 (gated by `delivery.go_live_not_before`;
      remove or move that config key to change the start date).
- Uninstall anytime: `launchctl bootout gui/$(id -u)/com.ivo.market.refresh`.

## Tuning after first live runs
- Thresholds + decay live in `config.json` (`tracks`, `rank_weights`, `regime`).
- Known gap to revisit: regime adapter Fear/Greed (CNN 418) + put/call (CBOE timeout) can fail
  → score degrades to VIX-only (marked "partial"); harden fetchers when convenient.
