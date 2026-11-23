// Runs in the meeting page itself (the MAIN world), before the page's own
// scripts, so every RTCPeerConnection the call opens is seen. A few times a
// second it asks each remote audio receiver which sources are loud: one
// contributing source (CSRC) per person where the server mixes people into a
// few streams (Google Meet, Teams), else one stream (SSRC) per person. While
// a source is loud it also reads the name on each tile the page marks as
// talking. On Google Meet it also reads every tile's name once a second
// (the roster, the user's own apart). Every ten seconds a diagnostic says how
// many receivers and sources it saw, the loudest level and how far the
// sources' clock sits from the page's. Only those ids, names and numbers,
// the time, and the page's host and path leave the page; no audio, video or
// other page content.
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
  // While anyone talks the state is repeated this often, so the app can tell
  // a pause in the call from a page that stopped reporting.
  const REPEAT = 1000;
  // The roster is read this often.
  const ROSTER_EVERY = 1000;
  // How often a diagnostic goes out while the tab is in a call. It also
  // tells the extension the call is still open during a long silence.
  const DIAGNOSE_EVERY = 10000;

  // Each source's timestamp and rtpTimestamp at the previous poll. A source
  // is playing when either moved since: comparing its timestamp with the
  // page's clock fails where the two clocks drift apart, which left every
  // source looking stale on Meet and Teams (webrtc issue 42222258).
  let previous = new Map();
  let diagnostic = { receivers: 0, sources: 0, maxLevel: 0, clockOffset: 0 };

  function loud() {
    const active = new Set(), current = new Map();
    let receivers = 0, count = 0, maxLevel = 0, clockOffset = null;
    for (const pc of peers) {
      if (pc.connectionState === 'closed' || pc.signalingState === 'closed') { peers.delete(pc); continue; }
      for (const receiver of pc.getReceivers()) {
        const track = receiver.track;
        if (!track || track.kind !== 'audio' || track.readyState !== 'live') continue;
        receivers += 1;
        const csrc = receiver.getContributingSources ? receiver.getContributingSources() : [];
        const sources = csrc.length
          ? csrc.map((s) => ['csrc', s])
          : (receiver.getSynchronizationSources ? receiver.getSynchronizationSources() : []).map((s) => ['ssrc', s]);
        for (const [kind, s] of sources) {
          count += 1;
          const id = `${kind}:${s.source}`, level = s.audioLevel || 0, stamp = `${s.timestamp}/${s.rtpTimestamp}`;
          maxLevel = Math.max(maxLevel, level);
          const behind = performance.timeOrigin + performance.now() - s.timestamp;
          if (Number.isFinite(behind)) clockOffset = clockOffset === null ? behind : Math.min(clockOffset, behind);
          if (level >= LOUD && previous.has(id) && previous.get(id) !== stamp) active.add(id);
          current.set(id, stamp);
        }
      }
    }
    previous = current;
    diagnostic = { receivers, sources: count, maxLevel: Math.round(maxLevel * 1000) / 1000, clockOffset: Math.round(clockOffset || 0) };
    return [...active].sort();
  }

  // How each service marks who is talking: its participant tiles, whether a
  // tile is lit as talking, and the name on it. The user's own tile is left
  // out. These are the services' own markup, which they change without
  // notice; a site whose markup no longer matches gives no names, never
  // wrong ones, and the app falls back to the screen and the notes model.
  const text = (element) => (element && element.textContent || '').replace(/\s+/g, ' ').trim();
  const SITES = [
    {
      // Each tile carries data-participant-id; Meet lights the talking tile
      // with one of these (obfuscated) classes, and marks the user's own
      // with data-self-name. Names are in notranslate spans.
      host: /^meet\.google\.com$/,
      tiles: '[data-participant-id]',
      self: (tile) => {
        if (tile.matches('[data-self-name]') || tile.querySelector('[data-self-name]')) return true;
        const own = document.querySelector('[data-self-name]');
        const ownTile = own && own.closest('[data-participant-id]');
        return !!ownTile && ownTile.getAttribute('data-participant-id') === tile.getAttribute('data-participant-id');
      },
      talking: (tile) => ['Oaajhc', 'HX2H7', 'wEsLMd', 'OgVli']
        .some((name) => tile.classList.contains(name) || !!tile.querySelector(`.${name}`)),
      name: (tile) => text(tile.querySelector('span.notranslate')),
      // Every tile, talking or not; Meet nests elements carrying the same
      // participant id, and a shared screen is another tile named
      // "… (Presentation)".
      roster: true,
    },
    {
      // Each stream wrapper names its person in data-tid; a talking person's
      // voice-level outline is marked with vdi-frame-occlusion.
      host: /^teams\.(microsoft|live)\.com$|^teams\.cloud\.microsoft$/,
      tiles: '[data-stream-type][data-tid]',
      self: () => false,
      talking: (tile) => !!tile.querySelector(
        '[data-tid="voice-level-stream-outline"].vdi-frame-occlusion, .vdi-frame-occlusion [data-tid="voice-level-stream-outline"]'),
      // data-tid also holds machine ids such as video-stream-2 or videoTile.
      name: (tile) => {
        const name = tile.getAttribute('data-tid').trim();
        return /^[\w-]+$/.test(name) && /[-_\d]|[a-z][A-Z]/.test(name) ? '' : name;
      },
    },
    {
      // The web client shows the active speaker in one large frame, with
      // the name in its footer.
      host: /(^|\.)zoom\.(us|com)$/,
      tiles: '.speaker-active-container__video-frame, .speaker-bar-container__video-frame--active, [class*="single-"][class*="-container__video-frame"]',
      self: () => false,
      talking: () => true,
      name: (tile) => text(tile.querySelector('.video-avatar__avatar-footer')),
    },
    {
      // Thumbnails are .videocontainer; the dominant speaker's gets
      // dominant-speaker; the user's own has the id localVideoContainer.
      host: /^meet\.jit\.si$/,
      tiles: '.videocontainer.dominant-speaker',
      self: (tile) => tile.id.startsWith('localVideoContainer'),
      talking: () => true,
      name: (tile) => text(tile.querySelector('.displayname')),
    },
  ];
  const site = SITES.find((s) => s.host.test(location.hostname));

  function talking() {
    if (!site) return [];
    const names = new Set();
    for (const tile of document.querySelectorAll(site.tiles)) {
      if (site.self(tile) || !site.talking(tile)) continue;
      const name = site.name(tile);
      if (name && name.length <= 80) names.add(name);
    }
    return [...names].sort().slice(0, 16);
  }

  // Everyone with a tile, the user's own apart, where the site draws a tile
  // for each person whether they talk or not.
  function roster() {
    if (!site || !site.roster) return null;
    const people = new Map();
    let me = '';
    for (const tile of document.querySelectorAll(site.tiles)) {
      const name = site.name(tile);
      // A shared screen is its presenter again, under an id of its own.
      if (!name || name.length > 80 || /\((?:presentation|presenting)\)$/i.test(name)) continue;
      if (site.self(tile)) { me = name; continue; }
      people.set(tile.getAttribute('data-participant-id') || name, name);
    }
    // Counted by participant id: two people can show the same name.
    const remote = [...new Set(people.values())].sort().slice(0, 64);
    return { remote, me, count: people.size + (me ? 1 : 0) };
  }

  let last = '', sentAt = 0, rosterAt = 0, diagnosedAt = 0, people = null;
  setInterval(() => {
    if (peers.size === 0) return;
    const active = loud(), now = Date.now();
    if (now - rosterAt >= ROSTER_EVERY) { people = roster(); rosterAt = now; }
    // A tile can stay lit after its person stops (Zoom and Jitsi keep the
    // last speaker), so names count only while someone is loud.
    const names = active.length ? talking() : [];
    const key = JSON.stringify([active, names, people]);
    const diagnose = now - diagnosedAt >= DIAGNOSE_EVERY;
    if (key === last && !diagnose && (!active.length || now - sentAt < REPEAT)) return;
    last = key; sentAt = now;
    const message = { voiceiq: 'speakers', t: now, active, names, page: location.host + location.pathname };
    if (people) Object.assign(message, { roster: people.remote, me: people.me, count: people.count });
    if (diagnose) { message.diag = diagnostic; diagnosedAt = now; }
    window.postMessage(message, location.origin);
  }, 250);
})();
