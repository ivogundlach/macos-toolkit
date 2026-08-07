// Force links to EXTERNAL sites to open in a new tab.
// Same-site links (including subdomains of the same base domain) are untouched.
(() => {
  "use strict";

  // Loose registrable-domain: last two labels ("news.ycombinator.com" -> "ycombinator.com").
  // Imperfect for co.uk-style suffixes, which only makes those cases MORE likely
  // to count as same-site (fail-safe: link opens normally).
  const baseDomain = (host) => host.split(".").slice(-2).join(".");

  const isGoogleSearchResultsPage =
    /^www\.google\.[a-z.]+$/i.test(location.hostname) &&
    location.pathname === "/search";

  document.addEventListener(
    "click",
    (e) => {
      if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = e.composedPath().find((n) => n.tagName === "A" && n.href);
      if (!a) return;
      let url;
      try {
        url = new URL(a.href);
      } catch {
        return;
      }
      if (url.protocol !== "http:" && url.protocol !== "https:") return;
      if (isGoogleSearchResultsPage) return;
      if (baseDomain(url.hostname) === baseDomain(location.hostname)) return;
      if (a.target === "_blank") return;
      a.target = "_blank";
      if (!/\bnoopener\b/.test(a.rel)) a.rel = (a.rel + " noopener").trim();
    },
    true
  );
})();
