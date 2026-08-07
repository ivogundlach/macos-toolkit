// Force Copy Paste — background. Toolbar button toggles the current site;
// colored when active, gray when inactive.
var api = typeof browser !== "undefined" ? browser : chrome;

var icons = {
  on: { "48": "icons/icon-48.png", "128": "icons/icon-128.png" },
  off: { "48": "icons/icon-off-48.png", "128": "icons/icon-off-128.png" }
};

function hostOf(url) {
  try { return new URL(url).hostname || null; } catch (e) { return null; }
}

async function getHosts() {
  return (await api.storage.local.get("hosts")).hosts || [];
}

function setIcon(tabId, on) {
  api.action.setBadgeText({ tabId: tabId, text: "" });
  api.action.setIcon({ tabId: tabId, path: on ? icons.on : icons.off });
}

function setIconForTab(tab, hosts) {
  var host = hostOf(tab.url);
  if (host) setIcon(tab.id, hosts.indexOf(host) !== -1);
}

async function syncOpenTabs() {
  var hosts = await getHosts();
  var tabs = await api.tabs.query({});
  tabs.forEach(function (tab) { setIconForTab(tab, hosts); });
}

api.action.onClicked.addListener(async function (tab) {
  var host = hostOf(tab.url);
  if (!host) return;
  var hosts = await getHosts();
  var wasOn = hosts.indexOf(host) !== -1;
  hosts = wasOn ? hosts.filter(function (h) { return h !== host; }) : hosts.concat(host);
  await api.storage.local.set({ hosts: hosts });
  setIcon(tab.id, !wasOn);
  api.tabs.sendMessage(tab.id, { enabled: !wasOn }).catch(function () {});
});

api.tabs.onUpdated.addListener(async function (tabId, info, tab) {
  if (!tab.url) return;
  var host = hostOf(tab.url);
  if (!host) return;
  var hosts = await getHosts();
  var current;
  try { current = await api.tabs.get(tabId); } catch (e) { return; }
  if (hostOf(current.url) !== host) return;
  setIconForTab(current, hosts);
});

syncOpenTabs();
