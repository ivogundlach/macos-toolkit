// Force Copy Paste — content script (runs at document_start, all frames).
//
// When enabled for the current host, it defeats the two ways sites block
// clipboard/selection:
//   1. Event handlers that call preventDefault() on copy/cut/paste/
//      contextmenu/selectstart/dragstart, or swallow Cmd+C/V/X/A on keydown.
//      A capture-phase listener on window fires before any page handler;
//      stopImmediatePropagation() keeps the page handler from ever running,
//      while NOT calling preventDefault() lets the browser's default action
//      (the actual copy/paste) proceed.
//   2. CSS user-select:none — overridden with an injected !important rule.
(function () {
  var api = typeof browser !== "undefined" ? browser : chrome;
  var enabled = false;

  var SHIELDED = ["copy", "cut", "paste", "contextmenu", "selectstart", "dragstart"];
  var CLIPBOARD_KEYS = { c: 1, v: 1, x: 1, a: 1 };

  function shield(e) {
    if (enabled) e.stopImmediatePropagation();
  }

  // Some sites block Cmd+C/V via keydown/keyup preventDefault instead of
  // clipboard events. Only intercept clipboard combos, never plain typing.
  function keyShield(e) {
    if (!enabled) return;
    if ((e.metaKey || e.ctrlKey) && CLIPBOARD_KEYS[(e.key || "").toLowerCase()]) {
      e.stopImmediatePropagation();
    }
  }

  SHIELDED.forEach(function (type) {
    window.addEventListener(type, shield, true);
  });
  window.addEventListener("keydown", keyShield, true);
  window.addEventListener("keyup", keyShield, true);

  var style = null;
  function setCss(on) {
    if (on && !style) {
      style = document.createElement("style");
      style.textContent =
        "*{-webkit-user-select:text!important;user-select:text!important;-webkit-touch-callout:default!important}";
      (document.head || document.documentElement).appendChild(style);
    } else if (!on && style) {
      style.remove();
      style = null;
    }
  }

  function setEnabled(on) {
    enabled = on;
    if (document.documentElement) setCss(on);
    else document.addEventListener("DOMContentLoaded", function () { setCss(enabled); });
  }

  api.storage.local.get("hosts").then(function (data) {
    var hosts = data.hosts || [];
    setEnabled(hosts.indexOf(location.hostname) !== -1);
  });

  // Live toggle from the toolbar button, no reload needed.
  api.runtime.onMessage.addListener(function (msg) {
    if (msg && typeof msg.enabled === "boolean") setEnabled(msg.enabled);
  });
})();
