// Make the YouTube header logo do a FULL page load of the home page instead
// of YouTube's in-app (SPA) navigation, so clicking it always refreshes.
(() => {
  "use strict";

  document.addEventListener(
    "click",
    (e) => {
      if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = e.composedPath().find((n) => n.tagName === "A" && n.href);
      if (!a) return;
      // The header logo anchor: <a id="logo"> inside ytd-topbar-logo-renderer.
      if (a.id !== "logo" && !a.closest("ytd-topbar-logo-renderer")) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      // location.assign forces a real navigation (fresh load) even when the
      // URL equals the current one, unlike YouTube's SPA router.
      location.assign("https://www.youtube.com/");
    },
    true
  );
})();
