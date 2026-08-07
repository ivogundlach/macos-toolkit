# Nutrient Tracker

A native macOS (SwiftUI) long-term health tracker built around your documented
animal-based-keto protocol. It is **not** a macro tracker — you log your actual
diet and it (1) computes your micronutrient **gaps** against your targets and
recommends the cost/calorie-efficient fixes to close them, and (2) learns
**which foods drive which GI symptoms**.

## Requirements

- macOS 14+ on Apple Silicon
- Xcode **not** required — builds with the Swift Command Line Tools (`swiftc`).

> Why no Xcode: on this machine the SwiftData/`@State` macros aren't available
> (their plugins ship only with Xcode), and the SwiftPM `swift build` driver is
> broken in the current beta CLT. So the app is written without `@State`/
> `@Bindable`/`@Model` (it uses the `ObservableObject` + `@StateObject`
> architecture) and is compiled directly with `swiftc`. See `build.sh`.

## Build & run

```bash
./build.sh                       # -> build/NutrientTracker.app
open build/NutrientTracker.app   # launch
./build.sh --install             # build and replace /Applications/NutrientTracker.app
```

Drag `build/NutrientTracker.app` to `/Applications` if you want it permanent.

## Features

- **Today** — log foods from the bundled USDA database (search) or quick-add
  your fix/supplement protocol; see the day's energy, protein, and items.
- **Gaps & Fixes** — per-nutrient coverage vs. target (with the deficiency
  magnitude from your docs), recommended interventions to close open gaps, and
  a "saturated / don't over-supplement" watch list (iron, zinc, vitamin A, B12).
- **GI Tracking** — log symptoms (type, severity, time); the *Which foods do
  what* panel correlates foods eaten before each episode.
- **Trends** — Swift Charts of daily coverage per nutrient and GI episodes/day.
- **Settings** — edit daily targets, the GI correlation window, view profile.

The nine tracked gaps, magnitudes, supplement-form mandates, and the fix
catalog (sardines / beef liver / blue mussels / supplement stack) are seeded
directly from your `Nutrition.md` and `Deficency.md`.

## Data

- **USDA FoodData Central** — SR Legacy (2018-04) + Foundation Foods (2026-04-30),
  8,262 whole foods × 22 tracked nutrients, bundled as
  `Resources/usda_foods.sqlite` (read-only).
- Rebuild the DB from fresh USDA dumps:
  ```bash
  python3 tools/build_usda_db.py <sr_dir> <foundation_dir> Resources/usda_foods.sqlite
  ```
- Your logs are stored locally at
  `~/Library/Application Support/NutrientTracker/store.json`.

## Layout

```
Sources/NutrientTracker/
  App.swift            app entry + navigation state
  Model/               Nutrients, Catalog, Logs, Store (persistence)
  Data/FoodDB.swift    SQLite (USDA) access
  Engine/Engine.swift  gap math, recommendations, GI correlation
  UI/                  Today, Gaps, GI, Trends, Settings views
Resources/usda_foods.sqlite
tools/build_usda_db.py
build.sh
```

*Personal tracking tool that organizes your own documented protocol and USDA
food data. Not medical advice.*
