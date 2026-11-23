// Passes the page script's speaker events to the extension's service worker.
// The page can post anything, so only the expected shape goes on.
// The worker injects this file again into open call pages after the
// extension reloads; a relay whose extension context is still alive stays
// the only one.
(() => {
if (globalThis.__voiceiqRelayAlive && globalThis.__voiceiqRelayAlive()) return;
globalThis.__voiceiqRelayAlive = () => { try { return !!chrome.runtime.id; } catch { return false; } };
window.addEventListener('message', (event) => {
  const data = event.data;
  if (event.source !== window || !data || data.voiceiq !== 'speakers') return;
  if (typeof data.t !== 'number' || !Array.isArray(data.active) || typeof data.page !== 'string') return;
  const active = data.active.filter((id) => typeof id === 'string' && id.length <= 40).slice(0, 64);
  const names = (value, limit) => (Array.isArray(value) ? value : [])
    .filter((name) => typeof name === 'string' && name.length > 0 && name.length <= 80).slice(0, limit);
  const message = { t: data.t, active, names: names(data.names, 16), page: data.page.slice(0, 300) };
  if (Array.isArray(data.roster)) message.roster = names(data.roster, 64);
  if (typeof data.me === 'string' && data.me.length > 0 && data.me.length <= 80) message.me = data.me;
  if (Number.isInteger(data.count) && data.count >= 0 && data.count <= 1000) message.count = data.count;
  const diag = data.diag;
  if (diag && typeof diag === 'object') {
    const numbers = {};
    for (const key of ['receivers', 'sources', 'maxLevel', 'clockOffset']) {
      if (typeof diag[key] === 'number' && Number.isFinite(diag[key])) numbers[key] = diag[key];
    }
    message.diag = numbers;
  }
  chrome.runtime.sendMessage(message).catch(() => {});
});
})();
