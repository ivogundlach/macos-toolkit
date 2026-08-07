# Warm Corners

A hot-corners launcher with a per-corner **dwell delay**: the pointer has to rest
in a corner for that corner's delay before the app opens, so brushing past a
corner does nothing. Delay `0` behaves exactly like a plain hot corner.

Built to replace the App Store *Hot Corners* app (`com.hotcorners.app.prod`),
whose corner assignments are imported automatically on first launch.

## Behavior

- Menu-bar only (`LSUIElement`); status item menu has Settings, Pause, Start at
  Login, Quit. Re-opening the app (Finder/Spotlight/`open -a`) shows Settings.
- Corner hit zone is 6 pt; after firing, a corner stays latched until the pointer
  leaves a 40 pt release zone, so jitter cannot double-fire.
- Works on every attached display — a corner is any corner of any screen.
- Optional countdown ring in the corner fills while the delay runs.
- No Accessibility permission needed: detection uses `NSEvent` mouse-moved
  monitors, not an event tap. A still pointer costs zero CPU — the only timer
  that ever runs is the one counting out a dwell.

## Build

```bash
./build.sh              # compile, sign as "Ivo Market Dev", install to /Applications
NO_DEPLOY=1 ./build.sh  # compile only
```

`scripts/make-icon.sh` regenerates `Icon/AppIcon.icns` from the SVG (needs
`rsvg-convert`); `build.sh` runs it when the SVG is newer.

## Settings storage

One JSON blob in `UserDefaults` under `com.ivogundlach.WarmCorners` →
`warmcorners.config`. Deleting that key makes the next launch re-import from
Hot Corners.
