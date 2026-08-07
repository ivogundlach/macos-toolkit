# Force Copy Paste (Safari)

Safari Web Extension that re-enables copy, cut, paste, text selection, and
right-click on sites that block them. Free replacement for the paid
"Enable Copy for Safari".

## Use

- Click the toolbar button to toggle for the current site (colored when on, gray when off).
- Default is OFF everywhere — the event shield would otherwise break sites
  that legitimately handle clipboard events (Google Docs, rich editors).

## How it works

`extension/content.js` registers capture-phase listeners on `window` at
`document_start`. When enabled, `stopImmediatePropagation()` keeps page
handlers for copy/cut/paste/contextmenu/selectstart/dragstart (and
Cmd+C/V/X/A keydown blockers) from running, while the browser's default
action still proceeds. CSS `user-select: none` is overridden with an
injected `!important` rule.

## Build / install (no Xcode)

    scripts/build-safari-clt.sh          # NO_DEPLOY=1 to skip install

Compiles the appex + faceless host app with CLT only, signs with the Apple
Development identity (team Q2X7X86GYR), installs to /Applications. Safari
registers it as a SIGNED extension, so it persists across relaunches —
Allow Unsigned Extensions is NOT needed. Enable once in Settings → Extensions.
