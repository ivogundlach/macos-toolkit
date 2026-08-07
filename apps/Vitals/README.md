# Vitals

A denser, energy-focused Activity Monitor replacement for Apple Silicon, with a
GPU tab, per-process energy in real milliwatts, battery-drain diagnosis, and a
configurable menu bar readout.

Built for an M1 Pro on macOS 26/27. SwiftUI, single-file `swiftc` build, signed
with the `Ivo Market Dev` identity.

## Why it exists

Activity Monitor has three gaps this fills:

1. **It hides processes.** ~200 root-owned daemons (`mdworker_shared`, `backupd`,
   `corecaptured`) are where mystery battery drain lives. Vitals lists all of them
   and can measure them with an opt-in helper.
2. **No GPU, no real energy.** Vitals adds a GPU tab, a per-process GPU column, and
   real per-process energy in milliwatts — not Activity Monitor's opaque "Energy
   Impact" score.
3. **Low density.** 18pt monospaced rows fit roughly twice as many processes on
   screen, with more columns.

## What is measured, and how

| Metric | Source | Privilege |
|---|---|---|
| Per-process energy (nJ), wakeups, P/E-core split, cycles, disk | `proc_pid_rusage(RUSAGE_INFO_V6)` | own uid only |
| Per-process GPU time | `AGXDeviceUserClient.AppUsage` accumulated Metal queue time, keyed by creator pid | none |
| GPU util %, VRAM | `IOAccelerator` `PerformanceStatistics` | none |
| GPU rail watts | `IOReport` "Energy Model" group via `dlopen(/usr/lib/libIOReport.dylib)` | none |
| System watts, battery health, cycles | `AppleSmartBattery` `PowerTelemetryData` | none |
| CPU / ANE / DRAM rail watts | `powermetrics` (root) | helper only |

**Key constraint:** on Apple Silicon, only the *GPU* energy channel moves in
IOReport unprivileged — a survey of all ~9,500 channels confirmed CPU/ANE/DRAM
rails are root-only. So CPU power shown is *attributed* power: the sum of real
per-process `ri_energy_nj`. It tracks load closely (measured 0.3 W idle → 7.4 W
across four busy P-cores). The Energy tab labels this honestly and shows an
"unaccounted" figure rather than inventing a CPU rail number.

## Tabs

**Processes is the only live tab.** Every other tab is a retrospective view of one
resource, read from the SQLite store over a **Day / Week / Month** window — hour by
hour for a day, day by day for a week and a month. They redraw when the window
changes or a reload lands, never on the sampling tick: a panel whose rows appear and
vanish every two seconds cannot actually be read, and numbers that jump are numbers
nobody trusts.

- **Processes** — the dense sortable/filterable live table; scopes All / Mine / Active / Needs Helper.
- **Energy** — average/peak draw, energy used, battery change, a system-draw and a
  battery chart, top drainers, battery detail, and **Findings** derived from the
  whole window rather than from one instant.
- **CPU** — load over time, attributed CPU power, top CPU consumers.
- **GPU** — utilisation over time, measured GPU rail power, top GPU consumers.
- **Memory** — used memory over time, largest memory users, live composition breakdown.

Each retrospective tab carries one small **Right Now** card for facts a time series
cannot express — battery health and cycle count, core layout, the GPU itself,
installed memory. Battery health lives there deliberately: it is a fixed property of
the machine, so it belongs somewhere it can be looked up, not in a findings list that
re-announces it forever.

Every window states its own **coverage** — the share of the span that has recording
behind it. Coverage counts distinct 30-second slots rather than rows, because the app
and the background recorder both write, and counting rows would report a half-recorded
day as fully covered. Anything derived by multiplying an average by elapsed time
(notably "Energy Used") is scaled by it.

## The optional privileged helper

Closes the visibility gap for other-user processes. Deliberately minimal: a root
LaunchDaemon (`com.ivogundlach.vitals.helper`) that reads kernel counters and
publishes them to one world-readable file (`/var/run/vitals-counters.json`). It
takes no arguments, opens no sockets or IPC, and does nothing but read counters —
there is no channel for the unprivileged side to influence it. Installed on one
admin authorization from Settings → Access, removable anytime.

## Start at login

Settings → General → **Start at login** registers the app with `SMAppService.mainApp`,
so it launches with the session **in the menu bar only** — no window, no Dock icon.
Opening Vitals yourself still opens the window normally.

The two cases are told apart by the open-application Apple event, which carries a
property saying loginwindow started the process. `--menu-bar` forces the same path,
which is how it can be tested without logging out.

`SMAppService.mainApp` is used rather than a LaunchAgent invoking the executable:
the app is launched through LaunchServices, so it stays a normal foreground-capable
app (flipping to `.regular` and activating when the window opens still works) and
macOS will not start a second copy of an already-running app. Because the switch is
the same one as System Settings → General → Login Items, that is treated as the
source of truth — there is no shadow preference to disagree with it. It is enabled
once on first run and remembered, so turning it off is not undone on the next launch.

## Background history sampler

Settings → Recording installs a per-user LaunchAgent that runs the same binary with
`--daemon`, recording a sample every 30s so overnight drain is answerable. Also
removable anytime.

Because the Energy, CPU, GPU and Memory tabs are built entirely from these
recordings, this is what makes their Week and Month views meaningful rather than
sparse. Retention defaults to 30 days so the Month view has something behind it.

The store keeps two tables: machine-level `samples`, and `proc_samples` holding the
top processes per instant — ranked by energy, and topped up with the leaders on GPU,
wakeups, CPU and memory so a process that only stands out on one of them is still
recorded. Retrospective queries bucket in SQL, since a month is ~86,000 rows and the
charts only ever draw 30 bars from them.

## Build

```bash
./build.sh            # compile, sign, install to /Applications/Vitals.app
NO_DEPLOY=1 ./build.sh # compile only, no signing/install
```

`Sources/main.swift` branches into headless daemon mode on `--daemon` before
SwiftUI starts, so the app and the background recorder are one binary and can
never drift apart. `--menu-bar` starts the UI with no window, the same state a
login launch produces:

```bash
open -a Vitals --args --menu-bar   # menu bar only, as if launched at login
```

## Layout

```
Sources/
  main.swift            entry point + daemon branch
  Sampling/             probes + engine + history store (no UI)
  Views/                SwiftUI tabs + AppModel
  MenuBar/              status-item label + dropdown panel
  Helper/               app-side helper management + install UI
  HelperDaemon/         the root helper binary (compiled separately)
  Support/              theme tokens + formatters
```
