# Psephos — U.S. Election Simulator

A native macOS app to simulate future Presidential, Senate, and House elections — chaining
scenarios across cycles, reapportioning House seats from census population, and modeling the
House generic ballot from real racial-group composition × voting behavior.

Built without Xcode (`swiftc` + Observation, like MacroSimulator / WorldCup2026Bracket).

## Build & run

```bash
./run.sh          # builds if needed, launches Psephos.app
./build.sh        # regenerate data + compile + bundle
./tools/fetch.sh  # re-download the real source data (Census, senators)
```

Requirements: Command Line Tools (Swift 5/6 toolchain, macOS SDK 14+). No Xcode, no SwiftPM.

## What works today (Phase 1)

| Tab | What it does |
|---|---|
| **Overview** | All three chambers under the current scenario, at a glance. |
| **Senate** | The hero feature: today's 47–53 chamber chained through 2026 → 2034. Set a national environment per cycle, or force individual seats D/R. Answers "what does the Senate look like in 2032 if…". |
| **House** | Generic ballot built from each racial group's share of the electorate × turnout × Democratic support, then translated to seats. Sliders for group support, turnout, and projecting the electorate's composition to a future year. |
| **President** | Electoral-college cartogram from the 2024 baseline + a national-swing slider. Click any state to force its winner. Toggle EVs onto **projected 2030 apportionment**, and make **any state split its EVs by congressional district** (2 to the statewide winner + 1 per district, on real 2024 per-CD results) — not just Maine/Nebraska. |
| **Apportionment** | Current (2020 Census) House seats vs **projected 2030** seats via Huntington–Hill on extrapolated population, with per-state Δ and electoral votes. |
| **Redistrict** | Full geographic redistricting for **15 states** (pick from a menu): 14 at whole-county granularity plus **Georgia at precinct level** (2,660 real voting precincts, since counties are too big there). Paint units into districts, live recompute of population / partisan lean / contiguity, and a **plausibility scorer** that compares your map to a per-state neutral ensemble (ReCom-style) — flagging it as typical, rare, or an extreme partisan outlier. |
| **Forecast** | **Monte Carlo** over your scenario: thousands of simulations with random national-environment and per-race error give win probabilities + outcome distributions for the Senate (chained to a target year), President, and House. One uncertainty slider scales it all. |

### Verified correctness (`tools/selftest`)
- Huntington–Hill reproduces the **entire** official 2020 apportionment (all 50 states, total 435; CA 52, TX 38, FL 28, NY 26). Electoral votes total 538.
- Demographic model on 2024 defaults → **48.2% two-party Dem, D 215 / R 220** (the actual 2024 House result).
- Senate baseline = **45 D / 2 I / 53 R** (caucus 47–53), straight from the current roster; cycles chain correctly 2026→2034.
- Redistricting: 99 Iowa counties load; the seed map recomputes to 1 Dem district, all contiguous; the ensemble histogram sums to its map count; a 3-Dem map scores as an extreme outlier (0 occurrences).
- Monte Carlo: Senate outcome probabilities sum to 1; histogram counts equal the simulation count; presidential mean Dem EV lands in a sane band.
- EV splitting: total stays 538; Maine splits 3D–1R and Nebraska 1D–4R by default; toggling Georgia yields 5D–11R of its 16.
- Georgia precinct pilot: 2,660 precincts load; seed map is contiguous and fully assigned; 15 pilots total.

## Data (all real, frozen offline by `tools/gen_data.py`)

| Dataset | Source | As of |
|---|---|---|
| 2020 apportionment population + seats | Census 2020 Apportionment, Table 1 | Apr 1, 2020 (fixed until 2030) |
| State population estimates | Census PEP, Vintage 2024 (POPESTIMATE2024) | Jul 1, 2024 |
| Senators (state, class, party) | unitedstates/congress-legislators | current |
| 2024 presidential two-party share by state | AP / Cook Political Report | 2024 general (approx) |
| 2024 presidential results **by congressional district** | jaytimm/PresElectionResults | 2024 general |
| Georgia precinct geometry + votes + population | MGGG (mggg-states/GA-shapefiles) | 2016 returns / 2010 pop |
| Group composition / turnout / support | ACS · Census CPS · Catalist / AP VoteCast / Pew | ~2024 (estimates, adjustable) |

`Resources/dataset.json` is the human-readable source of truth; `Sources/GeneratedData.swift`
embeds it so the app has no runtime file dependency.

## The model

- **Apportionment** — Huntington–Hill method of equal proportions. 2030 projection extrapolates
  each state's 2020→2024 census trend forward (CAGR), then re-runs the method. It's a *projection*.
- **House** — `demShare = Σ(compositionɡ × turnoutɡ × supportɡ) ÷ Σ(compositionɡ × turnoutɡ)`;
  seats via a uniform-swing curve (responsiveness 2.0, calibrated to 2024).
- **Senate** — each seat's winner = state lean (2024 pres proxy) + per-cycle national environment
  + incumbency, unless you force it. Class II:2026/2032, III:2028/2034, I:2030/2036.
- **President** — 2024 two-party share + national swing → state winners → electoral votes (current
  or projected-2030 apportionment).

## Phase 2 — geographic redistricting (done, 14 states)

`tools/fetch.sh` pulls real county geometry (Census TIGER via plotly), 2020 county presidential
returns (tonmcg), county population (Census PEP), and the Census county-adjacency graph;
`data/build_pilots.py` builds, **for every state where county-granularity is valid**, a pilot with
its own **neutral redistricting ensemble** — 2,000 contiguous, population-balanced maps via
recursive spanning-tree (ReCom-style) bipartition — recording the Democratic-seat distribution.
The app embeds them and scores any map you draw against the right state's ensemble.

A state qualifies iff it has ≥2 districts, a connected county graph, and **no single county larger
than an ideal district** (else a balanced contiguous county partition can't exist). 14 states
qualify (AL AR ID IA KS LA ME MS MT NE NH NM SC WV); the other 36 are reported with the reason —
25 because a big urban county (Maricopa, Los Angeles, King, …) exceeds a district and needs
sub-county units, 6 single-district, plus Hawaii (islands) and Connecticut (county data). Whole-
county redistricting is faithful here, not an approximation (Iowa literally does it this way).
Example result: across 2,000 neutral Iowa maps, Democrats win 3–4 of 4 seats in **zero** of them.

To go further: large-county states need precinct/VTD geometry instead of counties.

## Phase 3 — Monte Carlo (done)

`Sources/MonteCarlo.swift` runs thousands of seeded simulations around your current scenario. The
Senate chains stochastically through every cycle to a target year (each cycle draws a national
environment; each race adds idiosyncratic noise); the President and House draw national + local
error. Outputs: P(majority/win) and full outcome distributions, with one uncertainty slider.

## Roadmap
- Precinct-level redistricting for more large-county states (Georgia is the pilot; `build_ga_precincts.py` generalizes to any MGGG-style precinct shapefile).
- Correlated (not independent) state errors in the presidential Monte Carlo.

## Caveats
- Electoral-vote splits use 2024 congressional-district lines/results; combining a split with the projected-2030 apportionment basis keeps a split state on its current-district count.
- 2030 seat counts and future demographics are projections, labeled as such and user-editable.
- Group support/turnout defaults are validated-voter *estimates*; the whole point is to adjust them.
