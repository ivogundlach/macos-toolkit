# YouTube Defaults

A minimal Safari Web Extension that changes only bare YouTube channel visits:

- If the channel's first content tab is **Videos**, it opens Videos.
- If the channel's first content tab is **Live**, it opens Live.
- Explicit links to Home, Videos, Live, Shorts, Podcasts, Playlists, and other pages remain unchanged.
- Newly loaded YouTube videos default to **2× playback speed**, with YouTube's speed selector kept in sync. Manual speed changes remain available.
- The keyboard play/pause key stays synchronized with YouTube instead of briefly pausing and immediately resuming.
- Playlist videos stop when they finish instead of automatically advancing.
- On a watch page, an opened side panel (chapters, transcript, description) sits **above** the playlist panel instead of below it.
- Missing **Save** and creator-heart glyphs receive delayed inline SVG fallbacks that yield to YouTube's native icons.
- The sidebar's **You** section appears before **Subscriptions**.

The extension reads the tab order rendered by YouTube. It identifies legacy links and current tab components by their canonical URL (`/videos` or `/streams`), so it does not depend on the interface language.
It activates YouTube's own tab link, preserving client-side navigation without a full-page refresh.

## Install in Safari

Open `Safari/YouTube First Content Tab/YouTube First Content Tab.xcodeproj` in Xcode, choose your personal development team under **Signing & Capabilities** for both targets if Xcode requests it, then press **Run**.

In Safari, open **Settings → Extensions**, enable **YouTube Defaults**, and allow access to YouTube when prompted.

For local development, Safari may require **Develop → Allow Unsigned Extensions** after enabling the Develop menu in **Settings → Advanced**.

## Source extension

The browser-extension source is in `Extension/`. It is also compatible with Chromium browsers via **Load unpacked**.
