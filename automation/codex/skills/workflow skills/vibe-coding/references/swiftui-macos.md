# SwiftUI macOS Workflow

Use this reference for SwiftUI macOS builds, packaging, signing, installation, or app-identity changes. Detect the current environment; do not assume the machine is still CLT-only.

## Start with the Project

1. Read the project `.memory/`, README, and build or packaging scripts.
2. Use an established project wrapper as the source of truth. Do not replace it with a generic build command merely because another toolchain now works.
3. Preserve project-specific generation, resources, signing identities, installation destinations, and post-build steps.

Known routes:

- `/Users/YOUR_USERNAME/Projects/WorldCup2026Bracket`: use `./build.sh`; it regenerates embedded data, compiles, bundles, signs, and deploys unless `NO_DEPLOY=1`.
- `/Users/YOUR_USERNAME/Projects/Market/app`: use `./scripts/build.sh` for binaries and `./packaging/build-app.sh` for the signed app bundle. `build.sh` always invokes `setup-swiftpm-toolfix.sh`; that setup script probes the CLT `swift-package` launcher and removes its stale toolfix when the launcher works. Preserve the `Ivo Market Dev` signing identity when available because notifications depend on stable signing.

## Detect the Toolchain

Run `xcode-select -p`, `swift --version`, and the project's existing probe or build wrapper.

- When full Xcode is selected, use the project's normal Xcode, SwiftPM, or `swiftc` path. Do not remove `@State`, `@Bindable`, `@Model`, or SwiftData merely because older CLT-only builds could not expand their macros.
- When `/Library/Developer/CommandLineTools` is selected, run `/Users/YOUR_USERNAME/.local/bin/swift-smoke` to verify the base SwiftUI compiler and SDK. Its built-in probe does not use `@State`, `@Bindable`, `@Model`, or SwiftData, so a passing smoke probe does not prove macro support. Verify needed macros with the actual project or a targeted type-check. If the compiler reports a missing `SwiftUIMacros` or `SwiftDataMacros` plugin, avoid only the affected macros and follow an existing project fallback such as `ObservableObject`, `@StateObject`, `@ObservedObject`, `@Published`, explicit bindings, or Codable/JSON persistence.
- Test SwiftPM instead of assuming it is broken. Prefer an existing wrapper because it can safely detect and handle the historical `BuildServerProtocol.framework` launcher defect.

For Ivo's personal SwiftUI macOS apps, apply `.focusEffectDisabled()` to the root view passed into
`NSHostingView` to suppress the system blue focus halo while preserving native control focusability,
keyboard navigation/activation, and accessibility semantics. Verify the modifier is at that root and
the targeted build succeeds; yield only if Ivo explicitly requests visible focus indication or root
suppression is ineffective on that platform/surface.

## Build Without an Existing Wrapper

Prefer the native project build path. Use direct `swiftc` plus a hand-built `.app` bundle only when the project has no working build system or the request specifically requires it. Start from `xcrun --sdk macosx swiftc -parse-as-library -target "<project-derived target>" <sources> -o <binary>` and replace every placeholder from project evidence.

Derive the source list, SDK, architecture, deployment target, bundle identifier, resources, entitlements, and signing method from the project. Do not impose a universal target triple. A hand-built app normally needs `Contents/MacOS`, `Contents/Resources`, and a valid `Info.plist` containing `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName`, `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleVersion`, and `LSMinimumSystemVersion`.

For every newly created personal macOS app, a real bundled app icon is mandatory. Completion
requires a non-empty `.icns` or asset-catalog icon declared by `CFBundleIconFile` or the Xcode asset
configuration and copied into the built `.app`. Blank, default, missing, generic-placeholder, or
runtime-only SwiftUI icons do not satisfy this requirement. For simple native artwork, a
deterministic AppKit/Core Graphics generator may render the source PNGs that are then compiled into
the baked icon asset. Follow `design-taste` for naming, metaphor, and visual-quality requirements.

Follow the project's signing requirements. Ad-hoc signing with `codesign --force --sign - "AppName.app"` is acceptable for a simple local app only when no stable identity or entitlement-dependent feature requires otherwise.

## Preserve Permission Grants

For any app using privacy-sensitive TCC permissions—Accessibility, Input Monitoring,
Automation/Apple Events, Screen Recording, Full Disk Access, or similar—permission
continuity is a mandatory deployment gate:

- Before staging an update, inspect the installed canonical app and record its canonical
  path, bundle identifier, designated code requirement, signing identity, and entitlements.
  The staged bundle must preserve those identity inputs and entitlements unless Ivo gives
  fresh explicit approval for a deliberate migration.
- For a new permission-dependent app, choose and verify a stable signing identity before
  the first permission grant. Never use ad-hoc signing for an installed
  permission-dependent release; abort if the stable identity is unavailable.
- Abort before replacement on identity or entitlement drift, or whenever equivalence
  cannot be proven. Keep the canonical installed path and bundle identifier stable.
- After replacement, verify the installed bundle's identity, entitlements, and `Info.plist`,
  and report permission continuity separately from compilation and signature validity.
  Never use `tccutil reset`, remove/re-add permission rows, or repeated reauthorization as
  routine build, update, or recovery mechanics. If an unavoidable deliberate migration is
  required, disclose its exact cause and obtain fresh explicit approval before invalidating
  existing grants.

This gate governs the normal agent-authored update path; macOS/user decisions and
certificate expiry or revocation remain outside it.

## Install and Refresh

Install when Ivo requests installation, when the request clearly means updating the runnable app, or when the established project wrapper deploys by design. A compile-only or smoke-test request does not imply installation. Use the established destination and quit a running app only when replacement requires it.

For Ivo's own signed macOS apps, packaging is not complete until the verified
bundle is installed in the app's established Applications directory under one
canonical `AppName.app` name. Replace the prior canonical bundle and remove
renamed or suffixed copies such as `AppName.app.bak-*`; macOS treats those
copies as independent applications in Finder, Spotlight, Open dialogs, and
Launch Services. Do not retain old `.app` bundles in an Applications directory
as deployment backups. If rollback retention is genuinely required, store a
non-`.app` archive outside Applications and only when the workflow explicitly
requires it. Verify the installed bundle's signature and `Info.plist`, not only
the build output.

Refresh Launch Services, the Dock, or Launchie only when the installed app's name, bundle identifier, or icon changed. Use `imagegen` when the task requires generating or editing a bitmap icon.

When an installed icon or app identity changed and `/Applications/Launchie.app` exists, rebuild Launchie's cached app list with:

```bash
osascript -e 'tell application "Launchie" to quit' 2>/dev/null || true
defaults delete de.nick-friedrich.Launchie LaunchieCachedApps 2>/dev/null || true
open -a /Applications/Launchie.app
```

Confirm Launchie relaunches. This routine intentionally opens Launchie even if it was not previously running, so use it only when the installed app's icon or identity actually changed; do not clear its cache for unrelated builds.

## Single-instance runtime verification

Before every launch, inspect matching main-app processes by bundle identifier **and** resolved main executable path; exclude helper and XPC processes. If a matching app instance exists, do not launch another copy by default. Never use `open -n`, `open -na`, direct executable invocation, or an equivalent bypass to defeat single-instance behavior.

A staged build must not be launched while an installed copy with the same identity runs. Reuse only the exact artifact already running; otherwise, when the current scope already authorizes replacement or termination, first satisfy the preflight and restoration-readiness requirements below before any termination. Only then may the already-authorized graceful termination, zero-process wait/recheck, and one background-safe normal launch proceed. If zero matching processes cannot be established, skip runtime verification and report it; failure to establish background safety or restoration/readiness does not itself permit termination unless Ivo supplies the explicit authorization specified below.

Before terminating a running app for replacement, identify the main app by bundle identifier and its canonical resolved executable path, record whether it was running, and preflight by verifying that a documented background-safe, normal, single-instance-safe launch method and an available app-specific readiness signal exist, without launching another instance during preflight. Confirm the staged replacement—or a recoverable prior installation—is launchable; immediately before requesting a graceful quit, re-resolve identity and running state, request the graceful quit, wait a bounded interval, and recheck for zero matching main processes. If the app is still running or an unresolved save prompt/state-loss risk cannot be ruled out background-safely, stop without force. Forced termination requires separate authority unless an approved workflow explicitly protects the state. If background-safe restoration/readiness cannot be checked, do not terminate unless Ivo authorizes the expected stopped or unverified state.

After any authorized quit for replacement, whether replacement succeeds, fails, or is not attempted, restore the prior running state unless Ivo asked otherwise; apps that were previously stopped stay stopped. If replacement fails, restore the confirmed recoverable prior installation before any relaunch; if neither artifact is runnable, report `restoration impossible` and stop retrying. Re-resolve the installed executable, record the launch attempt time, launch it normally and background-safely when restoration is required, and verify the main process executable path and bundle identity against the installed artifact with at least two checks separated by two seconds within the app's bounded startup deadline. Separately verify that the observed process start time is later than the recorded launch attempt. Then require a documented app-specific health, IPC, or service signal; UI presence counts only when the project documents it as sufficient. A transient PID is insufficient. Use the exact phrase `launch attempted but unverified` only for inaccessible or inconclusive evidence; report known crash, launch, identity, or readiness failures as restoration failures.

For an agent-launched instance, record its PID, resolved executable path, and start time. Immediately after launch, verify exactly one matching main process. Abort verification on ambiguity or more than one match; close only an attributable agent-launched extra and disclose the event. Close an attributable instance only if it was launched solely for temporary verification and no restoration is required; never close an instance preserving a previously running state. Multiple instances are allowed only with Ivo's explicit authorization in the current turn for that bounded scenario.

## Measure a Running App Without Stealing Focus

Ivo's rule against foregrounding windows or moving his pointer stands even while diagnosing. These
work inside it:

- **Capture an occluded window:** `screencapture -o -x -l<windowID>`. Note that an app which pauses
  redraw when not visible returns **stale, byte-identical frames** — pixels can show you layout, but
  they cannot time anything.
- **Time a handler:** add a temporary `os.Logger` line, then
  `log stream --style compact --predicate 'subsystem == "…"'`.
- **Synthesise input:** build the `NSEvent` and deliver it **from inside the app** with
  `window.sendEvent(_:)`, behind an environment-variable gate. `CGEvent.postToPid` from another
  process does **not** reach SwiftUI's gesture recognisers — it looks like the code under test
  failed when in fact the harness did.
- **Foreground `sleep` is blocked** in this environment; use `python3 -c "import time; time.sleep(N)"`.

Strip every probe and logger before reporting done, and re-run the build. When two candidate fixes
are equally plausible but only one can be verified with the available harness, ship the verifiable
one and say why the other was set aside.

## Verify

Run the established build or the smallest relevant compile check. For an app bundle, confirm the expected binary and resources exist, validate its plist with `plutil -lint "AppName.app/Contents/Info.plist"`, and verify signing with `codesign --verify --deep --strict --verbose=2 "AppName.app"`. Launch the installed app only when the requested outcome implies a runtime smoke test. Report build, installation, launch, and refresh status separately.

For a newly created app, also inspect the installed bundle—not only the source or build output—and
verify all of the following:

- the app's declared icon key or asset configuration exists;
- the referenced `.icns` or compiled asset is present and non-empty in the installed bundle;
- the icon has been rendered or opened at least once for visual inspection, including a small-size
  check for recognizability;
- the app has one purposeful canonical name and no obsolete renamed `.app` copy remains;
- Launch Services and Launchie were refreshed as described above when the name, bundle identifier,
  or icon changed.
