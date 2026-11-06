// Runs in the meeting page itself (the MAIN world), before the page's own
// scripts, so every RTCPeerConnection the call opens is seen. A few times a
// second it asks each remote audio receiver which sources are loud: one
// contributing source (CSRC) per person where the server mixes people into a
// few streams (Google Meet, Teams), else one stream (SSRC) per person. Only
// those ids, the time, and the page's host and path leave the page; no
// audio, names, or page content.
(() => {
  if (window.__voiceiqSpeakers || !window.RTCPeerConnection) return;
  window.__voiceiqSpeakers = true;

  const peers = new Set();
  const Native = window.RTCPeerConnection;
  class Watched extends Native {
    constructor(...args) {
      super(...args);
      peers.add(this);
    }
  }
  Object.defineProperty(Watched, 'name', { value: 'RTCPeerConnection' });
  window.RTCPeerConnection = Watched;
  if (window.webkitRTCPeerConnection) window.webkitRTCPeerConnection = Watched;

  // audioLevel is linear: 0.01 is -40 dBov, below any speech and above silence.
  const LOUD = 0.01;
  // A source counts while it played this recently, in ms.
  const RECENT = 400;
  // While anyone talks the state is repeated this often, so the app can tell
  // a pause in the call from a page that stopped reporting.
  const REPEAT = 1000;

  // The spec stamps sources on the page's time origin plus performance.now(),
  // not on Date.now(), which can drift from it. A small value is an engine
  // that stamps relative to the page instead.
  const age = (timestamp) => (timestamp > 1e12 ? performance.timeOrigin : 0) + performance.now() - timestamp;

  function loud() {
    const active = new Set();
    for (const pc of peers) {
      if (pc.connectionState === 'closed' || pc.signalingState === 'closed') { peers.delete(pc); continue; }
      for (const receiver of pc.getReceivers()) {
        const track = receiver.track;
        if (!track || track.kind !== 'audio' || track.readyState !== 'live') continue;
        const csrc = receiver.getContributingSources ? receiver.getContributingSources() : [];
        const sources = csrc.length
          ? csrc.map((s) => ['csrc', s])
          : (receiver.getSynchronizationSources ? receiver.getSynchronizationSources() : []).map((s) => ['ssrc', s]);
        for (const [kind, s] of sources) {
          if ((s.audioLevel || 0) >= LOUD && age(s.timestamp) < RECENT) active.add(`${kind}:${s.source}`);
        }
      }
    }
    return [...active].sort();
  }

  let last = '', sentAt = 0;
  setInterval(() => {
    if (peers.size === 0) return;
    const active = loud(), key = active.join(','), now = Date.now();
    if (key === last && (!key || now - sentAt < REPEAT)) return;
    last = key; sentAt = now;
    window.postMessage({ voiceiq: 'speakers', t: now, active, page: location.host + location.pathname }, location.origin);
  }, 250);
})();
