const HOST = 'io.blue.voiceiq.browser';
// Without the host installed every connect fails at once.
const RECONNECT_MS = 30000;
let port = null, lostAt = 0;

function send(message) {
  try {
    if (!port) {
      if (Date.now() - lostAt < RECONNECT_MS) return;
      // An open port keeps this service worker alive during a call.
      port = chrome.runtime.connectNative(HOST);
      port.onDisconnect.addListener(() => { port = null; lostAt = Date.now(); });
    }
    port.postMessage(message);
  } catch {
    port = null;
  }
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (sender.id !== chrome.runtime.id || !sender.tab) return;
  send({ t: message.t, page: message.page, tab: sender.tab.id, active: message.active, names: message.names });
});

function announceInstalled() { send({ t: Date.now(), page: 'hello', tab: -1, active: [] }); }
chrome.runtime.onInstalled.addListener(announceInstalled);
chrome.runtime.onStartup.addListener(announceInstalled);
