const HOST = 'io.blue.voiceiq.browser';
const VERSION = chrome.runtime.getManifest().version;
// Without the host installed every connect fails at once.
const RETRY_MS = 30000;
// A host that ran this long and then stopped was replaced, by a VoiceiQ
// update say, rather than missing: connect again at once.
const RAN_MS = 5000;
// No call page has reported for this long: reloading now loses no meeting.
const CALL_QUIET_MS = 60000;
let port = null, failedAt = 0, connectedAt = 0, callAt = 0, quietTimer = null;

function send(message) {
  try {
    if (!port) {
      if (Date.now() - failedAt < RETRY_MS) return;
      // An open port keeps this service worker alive during a call.
      port = chrome.runtime.connectNative(HOST);
      connectedAt = Date.now();
      port.onDisconnect.addListener(() => {
        port = null;
        failedAt = Date.now() - connectedAt >= RAN_MS ? 0 : Date.now();
        checkForUpdate();
      });
    }
    port.postMessage({ ...message, version: VERSION });
  } catch {
    port = null; failedAt = Date.now();
  }
}

// VoiceiQ copies a new version of this folder over the old one when it
// updates, but Chrome keeps running the service worker it cached, also across
// restarts, while chrome://extensions already shows the new manifest.
// MEASURED 2026-11-23, Chrome 157: the cached worker survived three restarts;
// chrome.runtime.reload() swapped it at once. The folder is read from disk on
// every fetch, so a version there that differs from the running one is an
// update. A reload cuts off the content scripts of open call tabs, so it
// waits until no call page has reported for a minute; the check runs when
// this worker starts, when the host goes away, and once each call goes quiet.
async function checkForUpdate() {
  let onDisk;
  try {
    onDisk = (await (await fetch(chrome.runtime.getURL('manifest.json'), { cache: 'no-store' })).json()).version;
  } catch {
    return; // Mid-copy, or the folder is gone: the next check decides.
  }
  if (typeof onDisk !== 'string' || onDisk === VERSION) return;
  if (Date.now() - callAt >= CALL_QUIET_MS) chrome.runtime.reload();
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (sender.id !== chrome.runtime.id || !sender.tab) return;
  // The page script reports only while the tab is in a call.
  callAt = Date.now();
  send({
    t: message.t, page: message.page, tab: sender.tab.id, active: message.active, names: message.names,
    roster: message.roster, me: message.me, count: message.count, diag: message.diag,
  });
  clearTimeout(quietTimer);
  quietTimer = setTimeout(checkForUpdate, CALL_QUIET_MS + 1000);
});

function announceInstalled() { send({ t: Date.now(), page: 'hello', tab: -1, active: [] }); }
chrome.runtime.onInstalled.addListener(announceInstalled);
chrome.runtime.onStartup.addListener(announceInstalled);
checkForUpdate();
