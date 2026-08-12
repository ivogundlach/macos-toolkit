# Kinetics

Kinetics is a small native macOS background utility for one job: making desktop
switching feel Crisp on macOS 27. Version 0.1.5 (build 6) ships Desktop Switching
and Dock Animations modules, one continuous target-duration control centered on
220 ms, and a Trackpad Override enabled by default. There is no menu-bar status item.

The target is deliberately described as calibrated. The Dock owns the final
compositor rendering; Kinetics maps the selected target to a DockSwipe ending
velocity. On macOS 27 the engine adds the serialized IOHID field 4205 payload,
uses the modern direction signs, keeps progress nonzero in fixed-point form,
and paces Began, Changed, and Ended phases about 10 ms apart. The private
CoreGraphics Services calls are bounds-aware and fail closed when space state
cannot be read.

## Build and install

```sh
cd /Users/YOUR_USERNAME/Projects/Kinetics
swift build -c release
./scripts/build.sh
```

Normal builds compile only and report the main and nested login-helper binary
paths. They do not assemble, sign, install, or modify an app bundle.

To install a local update on this Mac, run:

```sh
./scripts/build.sh --install
```

Install builds use the exact stable `Ivo Market Dev` certificate leaf
`12F05E96DC78DEF756913A2D574FF98F6C5BD485` and may prompt once for each nested
signing operation depending on the key's ACL. There is no continuity promise
beyond that exact certificate; certificate renewal or rotation requires an
explicit migration. The installer keeps a recoverable backup under
`/Users/YOUR_USERNAME/.local/state/kinetics-backups/` and verifies the signed
bundle before replacing `/Applications/Kinetics.app`.

Run the background-safe diagnostic mode without starting the UI or changing
spaces:

```sh
/Applications/Kinetics.app/Contents/MacOS/Kinetics --diagnose
```

`--switch-left` and `--switch-right` apply the current Crisp preferences, post
one bounded switch, pump the run loop through all phases, and exit with a
success or failure status.

Version 0.1.5 (build 6) adds a read-only-by-default Dock Animations module with
in-memory drafts and explicit Apply & Restart Dock behavior, while retaining the
modular collapsible Settings sections, native Trackpad Override, physical
Control-arrow matching and the 750 ms predicted-space reconciliation/expiry
fix.

## Runtime behavior

- The enabled macOS symbolic hotkeys for desktop switching are resolved from
  `com.apple.symbolichotkeys` (left IDs 79/80, right IDs 81/82). Kinetics uses
  the first enabled candidate in each direction. The standard IDs 80/82 are
  shown as the physical **Control-Left Arrow** / **Control-Right Arrow**
  shortcut even though macOS stores extra raw modifier bits; Kinetics normalizes
  the exact standard entries (IDs 80/82, keycodes 123/124, raw flags 8781824)
  to Control-only matching. Other customized shortcuts retain their literal
  modifier masks in Settings and diagnostics. If resolution fails, the clearly
  labelled fallback is **Control-Left/Right Arrow** and matches Control-only.
- The first ordinary launch opens one Settings window and activates the regular
  app. Reopening the app brings that same window forward. Closing it leaves the
  engine running as an accessory/background process with no Dock or status-item
  presence.
- Control/Option/Shift/Command shortcuts are intercepted only while Kinetics is
  enabled, Accessibility is trusted, the event tap is active, and the requested
  move is in bounds. A shortcut is swallowed only after the switch request is
  accepted; otherwise macOS receives it normally.
- **Trackpad Override** defaults on and only intercepts while the engine is
  enabled. It filters only real HID-origin horizontal DockControl swipes (CGS
  event type 30, HID type 23, horizontal motion 1,
  source Unix PID 0) and suppresses companion CGS gesture type 29 events only
  during an active native sequence. Synthetic and other non-HID events pass
  through. A native Began is suppressed, then the first Changed event whose
  absolute progress reaches 0.02 commits exactly one Crisp switch; if no such
  Changed event arrives, a nonzero Ended velocity provides the direction. The
  native sequence is bounded by a 750 ms inactivity window and resets on Ended,
  Cancelled, disable, or tap loss. This replaces Apple's interactive
  peek/cancel motion and does not provide continuous finger tracking.
- Accessibility is never requested automatically. Use **Open Accessibility
  Settings** in the settings window. An event-tap failure remains an explicit
  inactive state.
- **Follow system Reduce Motion** defaults on and uses the proven minimized-travel
  snap path when active. **Minimize spatial motion** is an independent optional
  switch and defaults off.
- Launch at Login registers the nested `Kinetics Login Launcher.app` through
  `SMAppService.loginItem(identifier:)` at
  `Contents/Library/LoginItems/Kinetics Login Launcher.app` (bundle ID
  `com.ivogundlach.Kinetics.LoginLauncher`). The helper starts the main app with
  `--login` without activation or recent-item insertion; login launches stay
  hidden and start the engine without opening Settings. Login is disabled by
  default and is never registered during build.
- **Dock Animations** reads `autohide-delay`, `autohide-time-modifier`, and
  `expose-animation-duration` from `com.apple.dock`. Installation and app startup add
  Kinetics' defaults only for keys that do not exist; existing values are never replaced.
  Slider edits remain in memory; **Apply & Restart Dock** writes all three values and
  restarts Dock. **Reload Current Values** discards drafts. `--diagnose` reports these
  values read-only and never writes or restarts Dock.

There is no direct-number shortcut, Cmd-Tab follow, updater, analytics, or networking
in this release.

## Attribution

The augmented event serialization and CoreGraphics Services inspection are
adapted from InstantSpaceSwitcher (MIT), commit
`c64e0fd09857330422084387cb98e8d1f4c3e2d1`. The complete license and attribution
and the trackpad override adaptation from commit
`fd37e7fed62ad862ec6326aa7dac9b7bc6b413e5` are in
`ThirdPartyNotices/InstantSpaceSwitcher-MIT.txt`, with source comments at the
adaptation boundary.
