# New Tab Links

Safari web extension: links to **external** websites open in a new tab instead of
replacing the current page. Same-site links (including subdomains sharing the base
domain) navigate normally. Modifier-clicks (⌘, ⇧, ⌥, ⌃) are left untouched.
Links clicked on Google Search result pages also navigate in the current tab.

## How it works
A content script ([extension/content.js](extension/content.js)) listens for clicks
at capture phase; when the clicked link's base domain differs from the page's, it
sets `target="_blank" rel="noopener"` before Safari handles the click. Domain
comparison is a loose last-two-labels match — `co.uk`-style suffixes err toward
"same site" (link opens normally), never toward extra tabs.

## Build & install (CLT only, no Xcode)
```
./scripts/build-safari-clt.sh        # builds, signs (Apple Development), installs to /Applications
NO_DEPLOY=1 ./scripts/build-safari-clt.sh
```
Same pipeline as ForceCopyPaste/knockoff: appex must be sandbox-entitled or pkd
rejects it; enable in Safari → Settings → Extensions (Develop → Allow Unsigned
Extensions is NOT needed — signed with the Apple Development identity).
