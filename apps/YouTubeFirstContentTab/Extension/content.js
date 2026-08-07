(() => {
  "use strict";

  const CHANNEL_ROOT = /^\/(?:@[^/]+|channel\/[^/]+|c\/[^/]+|user\/[^/]+)\/?$/;
  const CONTENT_TAB = /\/(?:videos|streams)\/?$/;
  const DEFAULT_PLAYBACK_RATE = 2;
  const GLYPH_FALLBACK_DELAY_MS = 1500;
  const MEDIA_PAUSE_GUARD_MS = 1500;
  const SVG_NAMESPACE = "http://www.w3.org/2000/svg";
  const SAVE_ICON_PATH = "M19 2H5a2 2 0 00-2 2v16.887c0 1.266 1.382 2.048 2.469 1.399L12 18.366l6.531 3.919c1.087.652 2.469-.131 2.469-1.397V4a2 2 0 00-2-2ZM5 20.233V4h14v16.233l-6.485-3.89-.515-.309-.515.309L5 20.233Z";
  const HEART_ICON_PATH = "M12 20.4 10.55 19C5.4 14.36 2 11.28 2 7.5 2 4.42 4.42 2 7.5 2c1.74 0 3.41.81 4.5 2.09A6.02 6.02 0 0 1 16.5 2C19.58 2 22 4.42 22 7.5c0 3.78-3.4 6.86-8.55 11.51L12 20.4Z";
  const QUEUE_ICON_PATH = "M4 6h12v2H4V6Zm0 5h12v2H4v-2Zm0 5h8v2H4v-2Zm14-5v3h-3v2h3v3h2v-3h3v-2h-3v-3h-2Z";
  const ARROW_UP_ICON_PATH = "m12 4-7 7 1.41 1.41L11 7.83V20h2V7.83l4.59 4.58L19 11l-7-7Z";
  const ARROW_DOWN_ICON_PATH = "m12 20 7-7-1.41-1.41L13 16.17V4h-2v12.17l-4.59-4.58L5 13l7 7Z";
  const LOCK_ICON_PATH = "M17 9V7A5 5 0 0 0 7 7v2H5v13h14V9h-2Zm-8-2a3 3 0 0 1 6 0v2H9V7Zm8 13H7V11h10v9Z";
  const PRIVACY_BADGE_LABELS = new Set(["private", "unlisted"]);
  const MENU_ICON_PATHS = new Map([
    ["add to queue", QUEUE_ICON_PATH],
    ["save to playlist", SAVE_ICON_PATH],
    ["move to top", ARROW_UP_ICON_PATH],
    ["move to bottom", ARROW_DOWN_ICON_PATH],
  ]);

  let scanTimer;
  let guideOrderFrame;
  let pageDefaultsFrame;
  let glyphFallbackTimer;
  let pendingLatestPath;
  const preparedVideos = new WeakSet();
  const mediaSession = navigator.mediaSession;
  const mediaSessionPrototype = mediaSession && Object.getPrototypeOf(mediaSession);
  const nativeSetActionHandler = mediaSessionPrototype?.setActionHandler;
  const mediaElementPrototype = HTMLMediaElement.prototype;
  const nativeMediaPlay = mediaElementPrototype.play;
  const nativeMediaPause = mediaElementPrototype.pause;
  let guardedVideo;
  let mediaPauseGuardUntil = 0;

  function activePlayer() {
    const player = document.querySelector("#movie_player");
    const video = player?.querySelector("video") || document.querySelector("video");
    return { player, video };
  }

  function handleMediaPause() {
    const { player, video } = activePlayer();
    guardedVideo = video;
    mediaPauseGuardUntil = performance.now() + MEDIA_PAUSE_GUARD_MS;
    if (typeof player?.pauseVideo === "function") {
      player.pauseVideo();
    } else {
      video?.pause();
    }
    navigator.mediaSession.playbackState = "paused";
  }

  function handleMediaPlay() {
    const { player, video } = activePlayer();
    guardedVideo = undefined;
    mediaPauseGuardUntil = 0;
    if (typeof player?.playVideo === "function") {
      player.playVideo();
    } else {
      video?.play().catch(() => {});
    }
    navigator.mediaSession.playbackState = "playing";
  }

  function installMediaSessionHandlers() {
    if (!mediaSession || typeof nativeSetActionHandler !== "function") return;
    try {
      nativeSetActionHandler.call(mediaSession, "pause", handleMediaPause);
      nativeSetActionHandler.call(mediaSession, "play", handleMediaPlay);
    } catch {
      // Older Safari versions may expose MediaSession without every action.
    }
  }

  function protectMediaSessionHandlers() {
    if (!mediaSessionPrototype || typeof nativeSetActionHandler !== "function") return;
    try {
      Object.defineProperty(mediaSessionPrototype, "setActionHandler", {
        configurable: true,
        writable: true,
        value(action, handler) {
          if (this === mediaSession && action === "pause") {
            return nativeSetActionHandler.call(this, action, handleMediaPause);
          }
          if (this === mediaSession && action === "play") {
            return nativeSetActionHandler.call(this, action, handleMediaPlay);
          }
          return nativeSetActionHandler.call(this, action, handler);
        },
      });
      installMediaSessionHandlers();
    } catch {
      // Leave unsupported implementations untouched.
    }
  }

  function protectMediaPause() {
    try {
      Object.defineProperty(mediaElementPrototype, "play", {
        configurable: true,
        writable: true,
        value(...args) {
          if (this === guardedVideo && performance.now() < mediaPauseGuardUntil) {
            return Promise.resolve();
          }
          return nativeMediaPlay.apply(this, args);
        },
      });
    } catch {
      // Leave unsupported implementations untouched.
    }
  }

  function applyDefaultPlaybackRate(video) {
    video.defaultPlaybackRate = DEFAULT_PLAYBACK_RATE;
    const player = document.querySelector("#movie_player");
    if (typeof player?.setPlaybackRate === "function") {
      player.setPlaybackRate(DEFAULT_PLAYBACK_RATE);
    } else {
      video.playbackRate = DEFAULT_PLAYBACK_RATE;
    }
  }

  function prepareVideo(video) {
    if (preparedVideos.has(video)) return;
    preparedVideos.add(video);
    installMediaSessionHandlers();

    video.addEventListener("play", () => {
      if (video !== guardedVideo || performance.now() >= mediaPauseGuardUntil) return;
      nativeMediaPause.call(video);
      navigator.mediaSession.playbackState = "paused";
    }, true);
    video.addEventListener("loadedmetadata", () => {
      installMediaSessionHandlers();
      applyDefaultPlaybackRate(video);
      requestAnimationFrame(() => applyDefaultPlaybackRate(video));
    });
    if (video.readyState >= HTMLMediaElement.HAVE_METADATA) {
      applyDefaultPlaybackRate(video);
      requestAnimationFrame(() => applyDefaultPlaybackRate(video));
    }
  }

  function prepareVideos(root) {
    if (root instanceof HTMLVideoElement) prepareVideo(root);
    root.querySelectorAll?.("video").forEach(prepareVideo);
  }

  function sectionHasPath(section, path) {
    return [...section.querySelectorAll("a[href]")].some((link) => {
      try {
        return new URL(link.href, location.href).pathname === path;
      } catch {
        return false;
      }
    });
  }

  function sectionTitle(section) {
    return section.querySelector("#guide-section-title, h3")?.textContent?.trim().toLowerCase();
  }

  function orderGuideSections() {
    const sections = [...document.querySelectorAll("ytd-guide-section-renderer")];
    const subscriptions = sections.find((section) =>
      sectionHasPath(section, "/feed/subscriptions") || sectionTitle(section) === "subscriptions"
    );
    const you = sections.find((section) =>
      sectionHasPath(section, "/feed/you") || sectionTitle(section) === "you"
    );

    if (!subscriptions || !you || subscriptions.parentElement !== you.parentElement) return;
    if (subscriptions.compareDocumentPosition(you) & Node.DOCUMENT_POSITION_FOLLOWING) {
      subscriptions.parentElement.insertBefore(you, subscriptions);
    }
  }

  function scheduleGuideOrder() {
    cancelAnimationFrame(guideOrderFrame);
    guideOrderFrame = requestAnimationFrame(orderGuideSections);
  }

  function createSvg(pathData, size = 24) {
    const svg = document.createElementNS(SVG_NAMESPACE, "svg");
    svg.setAttribute("height", String(size));
    svg.setAttribute("width", String(size));
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.style.cssText = "display:block;width:100%;height:100%;pointer-events:none";

    const path = document.createElementNS(SVG_NAMESPACE, "path");
    path.setAttribute("d", pathData);
    path.setAttribute("fill", "currentColor");
    svg.appendChild(path);
    return svg;
  }

  function removeSaveFallback(fallback) {
    const button = fallback.closest("button");
    fallback.remove();
    if (button && !button.querySelector(".ytSpecButtonShapeNextIcon")) {
      button.classList.remove("ytSpecButtonShapeNextIconLeading");
    }
  }

  function repairSaveIcons(allowFallback) {
    const selector = "button[aria-label='Save'], button[aria-label^='Save to ']";

    for (const fallback of document.querySelectorAll("[data-youtube-defaults-save-icon]")) {
      const button = fallback.closest("button");
      const nativeSvg = button && [...button.querySelectorAll("svg")].some((svg) =>
        !svg.closest("[data-youtube-defaults-save-icon]")
      );
      if (!button?.matches(selector) || nativeSvg) removeSaveFallback(fallback);
    }

    if (!allowFallback) return;

    for (const button of document.querySelectorAll(selector)) {
      if (button.querySelector("svg, [data-youtube-defaults-save-icon]")) continue;

      const icon = document.createElement("div");
      icon.dataset.youtubeDefaultsSaveIcon = "";
      icon.setAttribute("aria-hidden", "true");
      icon.className = "ytSpecButtonShapeNextIcon ytSpecButtonShapeNextElevatedContent";

      const wrapper = document.createElement("span");
      wrapper.className = "ytIconWrapperHost";
      wrapper.style.cssText = "display:inline-flex;width:24px;height:24px;flex:none";
      wrapper.appendChild(createSvg(SAVE_ICON_PATH));
      icon.appendChild(wrapper);

      button.classList.add("ytSpecButtonShapeNextIconLeading");
      button.insertBefore(icon, button.querySelector(".ytSpecButtonShapeNextButtonTextContent") || button.firstChild);
    }
  }

  function repairMenuIcons(allowFallback) {
    const itemSelector = "tp-yt-paper-item, ytd-menu-service-item-renderer, yt-list-item-view-model";

    for (const fallback of document.querySelectorAll("[data-youtube-defaults-menu-icon]")) {
      const host = fallback.parentElement;
      const item = fallback.closest(itemSelector);
      const nativeSvg = host && [...host.querySelectorAll("svg")].some((svg) =>
        !svg.closest("[data-youtube-defaults-menu-icon]")
      );
      if (!item || nativeSvg) fallback.remove();
    }

    if (!allowFallback) return;

    for (const item of document.querySelectorAll(itemSelector)) {
      const label = item.textContent?.trim().replace(/\s+/g, " ").toLowerCase();
      const pathData = MENU_ICON_PATHS.get(label);
      if (!pathData) continue;

      const host = item.querySelector("yt-icon, .yt-icon-shape, .ytIconWrapperHost");
      if (!host || host.querySelector("svg, [data-youtube-defaults-menu-icon]")) continue;

      const fallback = document.createElement("span");
      fallback.dataset.youtubeDefaultsMenuIcon = "";
      fallback.setAttribute("aria-hidden", "true");
      fallback.style.cssText = "display:block;width:24px;height:24px;color:inherit;pointer-events:none";
      fallback.appendChild(createSvg(pathData));
      host.appendChild(fallback);
    }
  }

  // YouTube renders Private/Unlisted badges as text only, dropping the lock
  // glyph that normally precedes the label. Give the badge a leading lock and
  // yield if YouTube ever hydrates a real icon.
  function repairPrivacyBadges(allowFallback) {
    for (const fallback of document.querySelectorAll("[data-youtube-defaults-lock-icon]")) {
      const badge = fallback.parentElement;
      const nativeSvg = badge && [...badge.querySelectorAll("svg")].some((svg) =>
        !svg.closest("[data-youtube-defaults-lock-icon]")
      );
      if (!badge || nativeSvg) fallback.remove();
    }

    if (!allowFallback) return;

    for (const badge of document.querySelectorAll("badge-shape.ytBadgeShapeHost")) {
      const label = badge.textContent?.trim().replace(/\s+/g, " ").toLowerCase();
      if (!PRIVACY_BADGE_LABELS.has(label)) continue;
      if (badge.querySelector("svg, [data-youtube-defaults-lock-icon]")) continue;

      const fallback = document.createElement("span");
      fallback.dataset.youtubeDefaultsLockIcon = "";
      fallback.setAttribute("aria-hidden", "true");
      fallback.style.cssText =
        "display:inline-flex;align-items:center;width:12px;height:12px;margin-right:4px;flex:none;color:inherit;pointer-events:none";
      fallback.appendChild(createSvg(LOCK_ICON_PATH, 12));

      if (getComputedStyle(badge).display === "inline") badge.style.display = "inline-flex";
      badge.style.alignItems = "center";
      badge.insertBefore(fallback, badge.firstChild);
    }
  }

  // The Save-to sheet lists each playlist's privacy as a bare "Private" line
  // with no lock, matching the badge defect above.
  function repairSheetPrivacyLabels(allowFallback) {
    for (const fallback of document.querySelectorAll("[data-youtube-defaults-sheet-lock]")) {
      if (!fallback.closest("yt-list-item-view-model")) fallback.remove();
    }

    if (!allowFallback) return;

    for (const row of document.querySelectorAll("yt-list-item-view-model")) {
      const subtitle = [...row.querySelectorAll("*")].find((node) =>
        node.children.length === 0 &&
        PRIVACY_BADGE_LABELS.has(node.textContent?.trim().toLowerCase())
      );
      if (!subtitle || subtitle.querySelector("[data-youtube-defaults-sheet-lock]")) continue;
      if (subtitle.previousElementSibling?.dataset.youtubeDefaultsSheetLock !== undefined) continue;

      const fallback = document.createElement("span");
      fallback.dataset.youtubeDefaultsSheetLock = "";
      fallback.setAttribute("aria-hidden", "true");
      fallback.style.cssText =
        "display:inline-flex;align-items:center;width:12px;height:12px;margin-right:4px;vertical-align:-2px;flex:none;color:inherit;pointer-events:none";
      fallback.appendChild(createSvg(LOCK_ICON_PATH, 12));
      subtitle.insertBefore(fallback, subtitle.firstChild);
    }
  }

  function removeEmptyPlaylistMenuTail() {
    for (const tail of document.querySelectorAll("[data-youtube-defaults-empty-menu-tail]")) {
      tail.style.removeProperty("display");
      delete tail.dataset.youtubeDefaultsEmptyMenuTail;
    }

    for (const listbox of document.querySelectorAll("ytd-menu-popup-renderer tp-yt-paper-listbox")) {
      const children = [...listbox.children];
      const labels = children.map((child) => child.textContent?.trim().replace(/\s+/g, " ").toLowerCase());
      const shareIndex = labels.indexOf("share");
      if (!labels.includes("save to playlist") ||
          !labels.includes("remove from playlist") ||
          shareIndex < 0) continue;

      for (const child of children.slice(shareIndex + 1)) {
        // A trailing separator can carry an empty interactive shell, so treat
        // only rendered text or a laid-out control as real content.
        const control = [...child.querySelectorAll("button, a, [role='menuitem']")]
          .find((node) => node.getBoundingClientRect().height > 0);
        if (child.textContent?.trim() || control) continue;
        child.dataset.youtubeDefaultsEmptyMenuTail = "";
        child.style.setProperty("display", "none", "important");
      }
    }
  }

  function repairCreatorHeartIcons(allowFallback) {
    const selector = "ytd-creator-heart-renderer, yt-creator-heart-renderer";

    for (const fallback of document.querySelectorAll("[data-youtube-defaults-heart-icon]")) {
      const renderer = fallback.closest(selector);
      if (!renderer || renderer.querySelector("#hearted svg, #hearted-border svg")) fallback.remove();
    }

    if (!allowFallback) return;

    for (const renderer of document.querySelectorAll(selector)) {
      if (renderer.querySelector("#hearted svg, #hearted-border svg, [data-youtube-defaults-heart-icon]")) continue;

      const anchor = renderer.querySelector("#creator-heart-button button, #creator-heart-button, button, #hearted-thumbnail") || renderer;
      const badge = document.createElement("span");
      badge.dataset.youtubeDefaultsHeartIcon = "";
      badge.setAttribute("aria-hidden", "true");
      badge.style.cssText = "position:absolute;right:-3px;bottom:-3px;display:block;width:15px;height:15px;padding:2px;box-sizing:border-box;border-radius:50%;color:white;background:#f00;pointer-events:none;z-index:1";
      badge.appendChild(createSvg(HEART_ICON_PATH, 11));

      if (getComputedStyle(anchor).position === "static") anchor.style.position = "relative";
      anchor.appendChild(badge);
    }
  }

  // YouTube stacks the playlist panel above #panels, so an opened chapters or
  // transcript panel lands below a long playlist. Put #panels first instead;
  // #panels collapses to zero height when no panel is open, so the layout is
  // unchanged until one is activated.
  function orderSecondaryColumn() {
    const column = document.querySelector("#secondary-inner");
    const playlist = column?.querySelector(":scope > ytd-playlist-panel-renderer#playlist");
    const panels = column?.querySelector(":scope > #panels");
    if (!playlist || !panels) return;
    if (playlist.compareDocumentPosition(panels) & Node.DOCUMENT_POSITION_FOLLOWING) {
      column.insertBefore(playlist, panels.nextSibling);
    }
  }

  function isPlaylistWatchPage() {
    return location.pathname === "/watch" && new URLSearchParams(location.search).has("list");
  }

  function disablePlaylistAutoplay() {
    if (!isPlaylistWatchPage()) return;

    const manager = document.querySelector("yt-playlist-manager");
    if (typeof manager?.set === "function") {
      manager.set("canAutoAdvance_", false);
    } else if (manager) {
      manager.canAutoAdvance_ = false;
    }

    document.querySelector(".ytp-autonav-toggle-button[aria-checked='true']")?.click();
  }

  // YouTube pads leading-icon pills to 16px on both sides, so the glyph sits
  // too far from the edge and too far from its label. Match the tighter
  // leading-icon spacing YouTube uses elsewhere.
  function ensureStyles() {
    if (document.getElementById("youtube-defaults-styles")) return;
    const style = document.createElement("style");
    style.id = "youtube-defaults-styles";
    style.textContent = `
      button.ytSpecButtonShapeNextIconLeading {
        padding-left: 14px !important;
        padding-right: 16px !important;
        column-gap: 6px;
      }
      button.ytSpecButtonShapeNextIconLeading > .ytSpecButtonShapeNextIcon {
        margin-right: 0 !important;
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  }

  function applyPageDefaults(allowGlyphFallback = false) {
    ensureStyles();
    repairPrivacyBadges(allowGlyphFallback);
    repairSheetPrivacyLabels(allowGlyphFallback);
    repairSaveIcons(allowGlyphFallback);
    repairMenuIcons(allowGlyphFallback);
    removeEmptyPlaylistMenuTail();
    repairCreatorHeartIcons(allowGlyphFallback);
    orderSecondaryColumn();
    disablePlaylistAutoplay();
  }

  function schedulePageDefaults() {
    cancelAnimationFrame(pageDefaultsFrame);
    pageDefaultsFrame = requestAnimationFrame(() => applyPageDefaults());
    if (!glyphFallbackTimer) {
      glyphFallbackTimer = setTimeout(() => {
        glyphFallbackTimer = undefined;
        applyPageDefaults(true);
      }, GLYPH_FALLBACK_DELAY_MS);
    }
  }

  function isBareChannelPage() {
    return location.hostname.endsWith("youtube.com") && CHANNEL_ROOT.test(location.pathname);
  }

  function redirectToFirstContentTab() {
    if (!isBareChannelPage()) return false;

    const channelPath = location.pathname.replace(/\/$/, "");
    const tabHeader = document.querySelector("ytd-tabbed-page-header");
    const renderedTabs = tabHeader?.tabs || [];
    const firstRenderedTab = renderedTabs.find((tab) => tab.tabRenderer)?.tabRenderer;
    if (firstRenderedTab && !firstRenderedTab.selected) return false;

    const tabShapes = tabHeader?.querySelectorAll("yt-tab-shape[role='tab']");
    let shapeIndex = 0;

    for (const tab of renderedTabs) {
      const renderer = tab.tabRenderer;
      if (!renderer) continue;

      const endpoint = renderer.endpoint?.commandMetadata?.webCommandMetadata?.url;
      const target = endpoint && new URL(endpoint, location.href);
      const isThisChannel = target?.pathname === `${channelPath}/videos` || target?.pathname === `${channelPath}/streams`;
      if (target?.origin === location.origin && isThisChannel && CONTENT_TAB.test(target.pathname) && tabShapes?.[shapeIndex]) {
        pendingLatestPath = target.pathname;
        tabShapes[shapeIndex].click();
        return true;
      }
      shapeIndex++;
    }

    for (const link of document.querySelectorAll("a[href]")) {
      const target = new URL(link.href, location.href);
      const isThisChannel = target.pathname === `${channelPath}/videos` || target.pathname === `${channelPath}/streams`;
      if (target.origin === location.origin && isThisChannel && CONTENT_TAB.test(target.pathname)) {
        pendingLatestPath = target.pathname;
        link.click();
        return true;
      }
    }
    return false;
  }

  function selectLatestSort() {
    const groups = [
      ...[...document.querySelectorAll("yt-chip-cloud-renderer")].map((group) => [group, "yt-chip-cloud-chip-renderer"]),
      ...[...document.querySelectorAll("chip-bar-view-model")].map((group) => [group, "chip-view-model"]),
    ];

    for (const [group, chipSelector] of groups) {
      const chips = [...group.querySelectorAll(chipSelector)];
      if (chips.length < 2) continue;

      const selectedIndex = chips.findIndex((chip) =>
        chip.matches("[selected], .iron-selected, [aria-selected='true']") ||
        chip.querySelector("[selected], .iron-selected, [aria-selected='true'], [aria-pressed='true']")
      );
      if (selectedIndex < 0) continue;

      if (selectedIndex > 0) {
        const latest = chips[0];
        (latest.querySelector("button, a, [role='tab'], [role='button']") || latest).click();
      }
      pendingLatestPath = undefined;
      return true;
    }
    return false;
  }

  function scheduleScan() {
    clearInterval(scanTimer);

    const startedAt = Date.now();
    const scan = () => {
      if (isBareChannelPage()) return redirectToFirstContentTab();
      if (location.pathname === pendingLatestPath) return selectLatestSort();
      pendingLatestPath = undefined;
      return true;
    };
    if (scan()) return;

    scanTimer = setInterval(() => {
      if (scan() || Date.now() - startedAt > 15000) {
        clearInterval(scanTimer);
      }
    }, 200);
  }

  protectMediaPause();
  protectMediaSessionHandlers();
  scheduleScan();
  scheduleGuideOrder();
  schedulePageDefaults();
  prepareVideos(document);
  new MutationObserver((mutations) => {
    let guideChanged = false;
    for (const mutation of mutations) {
      if (mutation.target instanceof Element && mutation.target.closest("ytd-guide-section-renderer")) {
        guideChanged = true;
      }
      mutation.addedNodes.forEach((node) => {
        prepareVideos(node);
        if (node instanceof Element &&
            (node.matches("ytd-guide-section-renderer") || node.querySelector("ytd-guide-section-renderer"))) {
          guideChanged = true;
        }
      });
    }
    if (guideChanged) scheduleGuideOrder();
    schedulePageDefaults();
  }).observe(document, { childList: true, subtree: true });
  addEventListener("popstate", () => {
    scheduleScan();
    scheduleGuideOrder();
    schedulePageDefaults();
  });
  addEventListener("yt-navigate-finish", () => {
    installMediaSessionHandlers();
    scheduleScan();
    scheduleGuideOrder();
    schedulePageDefaults();
  });
  addEventListener("yt-page-data-updated", schedulePageDefaults);
})();
