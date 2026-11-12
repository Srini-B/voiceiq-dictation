// Passes the page script's speaker events to the extension's service worker.
// The page can post anything, so only the expected shape goes on.
window.addEventListener('message', (event) => {
  const data = event.data;
  if (event.source !== window || !data || data.voiceiq !== 'speakers') return;
  if (typeof data.t !== 'number' || !Array.isArray(data.active) || typeof data.page !== 'string') return;
  const active = data.active.filter((id) => typeof id === 'string' && id.length <= 40).slice(0, 64);
  const names = (Array.isArray(data.names) ? data.names : [])
    .filter((name) => typeof name === 'string' && name.length > 0 && name.length <= 80).slice(0, 16);
  chrome.runtime.sendMessage({ t: data.t, active, names, page: data.page.slice(0, 300) }).catch(() => {});
});
