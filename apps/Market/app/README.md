# Market — native macOS SwiftUI hub

Front-end for the local stock-research pipeline. Reads `state/market.sqlite` via
the system `libsqlite3` and performs ALL writes through the Python `appctl` CLI,
exactly per `../CONTRACTS.md`. Zero third-party Swift dependencies (Apple
frameworks + system SQLite only). Builds with Command Line Tools — no Xcode.

## Build

```sh
# from app/
./scripts/build.sh            # debug   -> .build/debug/Market
./scripts/build.sh release    # release -> .build/release/Market
```

`build.sh` is a thin wrapper over `swift build`. It exists because of a defect in
THIS Command Line Tools install (see "CLT swift build defect" below); on a
healthy toolchain it is equivalent to running `swift build` / `swift build -c
release` directly.

The release binary lands at:

```
app/.build/release/Market        # arm64 Mach-O executable
```

Run it directly (it is a GUI app and opens a window):

```sh
./.build/release/Market
```

## Architecture (per CONTRACTS.md)

- **Reads** — `Sources/Market/Data/SQLite.swift` opens `state/market.sqlite`
  read-only with `PRAGMA query_only=ON; busy_timeout=5000` and WAL. Each screen
  loads inside ONE read transaction (`Repository.swift`). A schema-compat gate
  reads `meta.schema_version`/`min_supported`/`max_supported`; outside the
  supported range the app shows a friendly "backend needs migration" state
  instead of querying. Swift NEVER writes the DB and never does arithmetic.
- **Writes** — `Sources/Market/Data/AppCtl.swift` invokes
  `venv/bin/python pipeline/appctl.py <cmd> --json '<args>'` via
  `Foundation.Process` with an ARGUMENT ARRAY (no shell), absolute paths resolved
  from a single `ROOT` setting, a 30s timeout, off the main thread. It parses the
  single JSON envelope from stdout (`status/code/generation/config_version/
  run_id/message/data`) and surfaces command state (queued/running/succeeded/
  failed) plus `generation` for staleness detection.
- **Tolerance** — `appctl.py` is built in parallel and may be absent; new tables
  (`derived_state`, `positions`, `watchlists`, `notes`, `conviction_history`,
  `overrides`, `notifications`, `meta`) may not exist yet. Every new-table read is
  guarded by a `tableExists` check and degrades to an empty/placeholder state;
  every write button is disabled with a clear note when the backend CLI is
  missing. The app builds, launches, and reads the existing tables today.

## Views (left sidebar / NavigationSplitView)

1. **Overview** — redesigned dashboard surface: Market Conditions hero, Today's
   Signals, Market Breadth, Recent Changes, Portfolio, Top Picks, and Latest
   Debrief. Uses the shared `DashCard` system and plain `HStack`/`VStack`
   responsive columns.
2. **Recommendations** — Growth/Value/Dividends from `derived_state` (fallback
   `tracks`); row actions call `appctl override`
   (pin/unpin/force_exit/resolve_conflict). Ticker clicks open the drilldown.
3. **Today's Signals** — dense table from `signals` latest `session_date`:
   ticker, colored direction, strength, track, and friendly source labels.
4. **Watchlists & Positions** — list + add/edit/delete forms calling
   `appctl position-*` / `watchlist-*`; edits use atomic `position-replace`
   so a key-changing edit cannot be left half-applied. Imports TradingView
   `.txt` exports for watchlists and positions. Decimals stay as strings.
5. **Settings** — merged backend control surface: `ROOT`, health, source status,
   weights/thresholds, regime weights, denylist editor (`appctl denylist-*`),
   and alias editor (`appctl alias-*`).

Ticker Detail is not a sidebar screen. It is a drilldown reached by clicking a
ticker anywhere; it shows events/signals, conviction history, transitions/audit,
and notes with a Back affordance.

## Package and install

- Run `./packaging/build-app.sh`. It builds the release binary, assembles and
  signs `dist/Market.app` with the stable `Ivo Market Dev` identity, verifies
  the bundle, and installs exactly one canonical copy at
  `/Applications/Market.app`. It removes every other Applications bundle with
  the `com.ivo.market` identifier, regardless of its filename, so Finder and
  Launch Services cannot treat stale builds as apps.
- The release binary is `app/.build/release/Market` (arm64 Mach-O). It links
  only `/usr/lib/libsqlite3.dylib`, `SwiftUI.framework`, and `Charts.framework`
  — all present on the OS.
- `ROOT` defaults to `/Users/YOUR_USERNAME/Projects/Market` (stored in `UserDefaults` key
  `marketRoot`); editable in Settings. All backend paths resolve from it.
- The `.toolfix/` directory is a build-time SwiftPM shim only — do NOT ship it in
  the bundle.

## CLT swift build defect (environment note)

This Command Line Tools install (Swift 6.4, macOS 27, no Xcode) ships a
`swift-package` binary that is missing an rpath: it cannot load
`BuildServerProtocol.framework` / the SWB* plugin frameworks even though they
ship inside the toolchain at `usr/lib/swift/pm/`. The toolchain dir is read-only
under SIP and `DYLD_*` env vars are stripped for SIP-path binaries, so it cannot
be patched in place without root + SIP changes.

`scripts/setup-swiftpm-toolfix.sh` works around it (idempotent): it copies
`swift-package` into `app/.toolfix/` inside a directory mirror so its
`@executable_path/../lib` still resolves to the real CLT lib, symlinks every
needed toolchain framework into one folder, adds a single absolute rpath to that
folder, and ad-hoc re-signs the copy. `swift-build`/`swift-run`/`swift-test`
symlinks select the verb. `build.sh` runs the setup then builds. If a future CLT
fixes `swift-package`, the script detects that and becomes a thin pass-through.

The literal command `swift build` (via `/usr/bin/swift`) still fails because the
driver hardcodes the broken `swift-package` absolute path; use `./scripts/build.sh`
(or `.toolfix/usr/bin/swift-build`) instead. No app code is affected — this is
purely a toolchain-launcher defect.

## CLT-only limitations hit & worked around

- **Swift Charts**: available and compiles for the `arm64` target (the framework
  ships `arm64e`/`x86_64` interfaces that the compiler accepts for arm64). Used
  behind `#if canImport(Charts)` + `@available(macOS 13, *)`, with a hand-drawn
  `Path` chart fallback (`PathChart`) so the app degrades gracefully.
- **`@State` macro**: this SDK declares SwiftUI's `@State` as a macro backed by
  `SwiftUIMacros`, a plugin that does NOT ship in CLT (only `ObservationMacros` /
  `SwiftMacros` do). Bare `@State` therefore cannot expand. Every other property
  wrapper (`@StateObject`, `@ObservedObject`, `@EnvironmentObject`,
  `@Environment`, `@AppStorage`, `@Binding`, `@Published`) is a plain property
  wrapper and works. We use a drop-in `@ViewState` wrapper
  (`Views/Shared.swift`) that wraps SwiftUI's still-present `State` struct and
  conforms to `DynamicProperty`, so SwiftUI updates it identically to `@State`
  and `$value` yields a `Binding`.
