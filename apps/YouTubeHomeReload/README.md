# YouTube Home Reload (Safari)

Safari Web Extension: clicking the YouTube header logo forces a **full page
load** of youtube.com/ instead of YouTube's in-app (SPA) navigation, so the
home page always refreshes.

## How it works

`extension/content.js` adds a capture-phase click listener. When the click
lands on the header logo anchor (`a#logo` / inside
`ytd-topbar-logo-renderer`), it cancels YouTube's SPA routing and calls
`location.assign("https://www.youtube.com/")` — a real navigation, which
reloads even when already on the home page. Plain left-clicks only;
Cmd/Ctrl/Shift/middle clicks behave normally.

## Build / install (no Xcode)

    scripts/build-safari-clt.sh          # NO_DEPLOY=1 to skip install

Compiles the appex + faceless host app with CLT only, signs with the Apple
Development certificate ("Apple Development: you@icloud.example.com",
team Q2X7X86GYR), installs to /Applications. Safari treats this as a SIGNED
extension (its registry records the team ID, not "UNSIGNED"), so it persists
across Safari relaunches — no "Allow Unsigned Extensions" toggle needed.
Just enable it once in Safari → Settings → Extensions.
