#if canImport(JavaScriptCore)
import JavaScriptCore
import XCTest

/// The VoiceiQ Meetings extension's scripts, run in JavaScriptCore against
/// stand-ins for the meeting page and Chrome's extension APIs.
final class ChromeExtensionScriptTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/ChromeExtension")

    private func context(_ setup: String, script: String) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript(setup)
        context.evaluateScript(try String(contentsOf: Self.folder.appendingPathComponent(script), encoding: .utf8))
        XCTAssertNil(failure)
        return context
    }

    private func json(_ context: JSContext, _ expression: String) -> String? {
        context.evaluateScript("JSON.stringify(\(expression))")?.toString()
    }

    /// A Meet page with three tiles (Nihal lit as talking, the user's own
    /// marked) and one audio receiver whose contributing source reports a
    /// clock 5 s behind the page's, as drifting WebRTC clocks do.
    private let meetPage = """
    var window = this, messages = [], ticks = [], clock = 1000;
    window.postMessage = function (m) { messages.push(JSON.parse(JSON.stringify(m))); };
    window.setInterval = function (f) { ticks.push(f); };
    var performance = { timeOrigin: 1800000000000, now: function () { return clock; } };
    Date.now = function () { return performance.timeOrigin + clock; };
    var location = { hostname: 'meet.google.com', host: 'meet.google.com', pathname: '/abc-defg-hij', origin: 'https://meet.google.com' };
    function matches(n, sel) {
      var m;
      if ((m = /^\\[([\\w-]+)\\]$/.exec(sel))) return n.attrs[m[1]] !== undefined;
      if ((m = /^\\.([\\w-]+)$/.exec(sel))) return n.classes.indexOf(m[1]) >= 0;
      if (sel === 'span.notranslate') return n.tag === 'span' && n.classes.indexOf('notranslate') >= 0;
      return false;
    }
    function Node(tag, attrs, classes, text, children) {
      var node = this;
      this.tag = tag; this.attrs = attrs; this.classes = classes; this.textContent = text; this.children = children; this.parent = null; this.id = '';
      children.forEach(function (c) { c.parent = node; });
      this.classList = { contains: function (name) { return node.classes.indexOf(name) >= 0; } };
    }
    Node.prototype.getAttribute = function (name) { return this.attrs[name] === undefined ? null : this.attrs[name]; };
    Node.prototype.matches = function (sel) { return matches(this, sel); };
    Node.prototype.all = function () { var out = []; this.children.forEach(function (c) { out.push(c); out = out.concat(c.all()); }); return out; };
    Node.prototype.querySelector = function (sel) { return this.all().filter(function (n) { return matches(n, sel); })[0] || null; };
    Node.prototype.closest = function (sel) { var n = this; while (n) { if (matches(n, sel)) return n; n = n.parent; } return null; };
    function span(name) { return new Node('span', {}, ['notranslate'], name, []); }
    function tile(id, children) { return new Node('div', { 'data-participant-id': id }, [], '', children); }
    var body = new Node('body', {}, [], '', [
      tile('p1', [new Node('div', {}, ['Oaajhc'], '', []), span('Nihal')]),
      tile('p1', [span('Nihal')]),
      tile('p2', [span('Muhammed Hafeed')]),
      tile('p3', [new Node('div', { 'data-self-name': 'cyron' }, [], '', []), span('cyron')]),
      tile('p2/presentation', [span('Muhammed Hafeed (Presentation)')]),
    ]);
    var document = {
      querySelectorAll: function (sel) { return body.all().filter(function (n) { return matches(n, sel); }); },
      querySelector: function (sel) { return body.querySelector(sel); },
    };
    var source = { source: 11, audioLevel: 0.3, timestamp: performance.timeOrigin + clock - 5000, rtpTimestamp: 0 };
    var receiver = { track: { kind: 'audio', readyState: 'live' },
      getContributingSources: function () { return [source]; }, getSynchronizationSources: function () { return []; } };
    window.RTCPeerConnection = class { constructor() { this.connectionState = 'connected'; this.signalingState = 'stable'; } getReceivers() { return [receiver]; } };
    function tick(playing) {
      clock += 250;
      if (playing) { source.timestamp += 250; source.rtpTimestamp += 4000; }
      ticks[0]();
    }
    """

    func testASourcePlayingOnADriftedClockIsLoudAndTheRosterGoesOut() throws {
        let page = try context(meetPage, script: "page.js")
        page.evaluateScript("new RTCPeerConnection(); tick(true); tick(true); tick(true);")

        let last = json(page, "messages[messages.length - 1]")
        XCTAssertEqual(json(page, "messages[messages.length - 1].active"), #"["csrc:11"]"#, last ?? "")
        XCTAssertEqual(json(page, "messages[messages.length - 1].names"), #"["Nihal"]"#)
        XCTAssertEqual(json(page, "messages[messages.length - 1].roster"), #"["Muhammed Hafeed","Nihal"]"#)
        XCTAssertEqual(json(page, "messages[messages.length - 1].me"), #""cyron""#)
        XCTAssertEqual(json(page, "messages[messages.length - 1].count"), "3")
        XCTAssertEqual(json(page, "messages[messages.length - 1].probe"), "2")
        XCTAssertEqual(json(page, "messages[0].diag"), #"{"receivers":1,"sources":1,"maxLevel":0.3,"clockOffset":5000}"#)
    }

    func testTwoPeopleWithOneNameCountAsTwo() throws {
        let page = try context(meetPage + "body.children.push(tile('p4', [span('Nihal')])); body.children[body.children.length - 1].parent = body;", script: "page.js")
        page.evaluateScript("new RTCPeerConnection(); tick(true); tick(true);")

        XCTAssertEqual(json(page, "messages[messages.length - 1].roster"), #"["Muhammed Hafeed","Nihal"]"#)
        XCTAssertEqual(json(page, "messages[messages.length - 1].count"), "4")
    }

    func testASourceWhoseTimestampsStopIsNotLoud() throws {
        let page = try context(meetPage, script: "page.js")
        page.evaluateScript("new RTCPeerConnection(); tick(true); tick(false); tick(false); tick(false); tick(false);")

        XCTAssertEqual(json(page, "messages[messages.length - 1].active"), "[]")
    }

    /// Chrome's extension APIs, with the folder on disk at `onDisk`.
    private let chromeAPIs = """
    var reloads = 0, posted = [], timers = [], listeners = {}, onDisk = '1.2.0', now = 1800000000000;
    Date.now = function () { return now; };
    function event(name) { return { addListener: function (f) { listeners[name] = f; } }; }
    var chrome = { runtime: {
      id: 'voiceiq', getManifest: function () { return { version: '1.2.0' }; },
      getURL: function (path) { return 'chrome-extension://voiceiq/' + path; },
      reload: function () { reloads += 1; },
      onMessage: event('message'), onInstalled: event('installed'), onStartup: event('startup'),
      connectNative: function () { return { postMessage: function (m) { posted.push(m); }, onDisconnect: event('disconnect') }; },
    } };
    function fetch() { return Promise.resolve({ json: function () { return Promise.resolve({ version: onDisk }); } }); }
    function setTimeout(f, ms) { timers.push(f); return timers.length; }
    function clearTimeout(id) { if (id) timers[id - 1] = null; }
    function fireTimers() { var due = timers; timers = []; due.forEach(function (f) { if (f) f(); }); }
    var intervals = [];
    function setInterval(f, ms) { intervals.push(f); }
    """

    func testAnUpdatedFolderReloadsTheExtensionOnceNoCallIsOpen() throws {
        let worker = try context(chromeAPIs, script: "service-worker.js")
        XCTAssertEqual(json(worker, "reloads"), "0")

        worker.evaluateScript("""
        listeners.message({ t: 1, page: 'meet.google.com/abc', active: ['csrc:1'], names: [], roster: ['Nihal'] }, { id: 'voiceiq', tab: { id: 5 } });
        onDisk = '1.3.0';
        listeners.disconnect();
        """)
        XCTAssertEqual(json(worker, "posted[0].version"), #""1.2.0""#)
        XCTAssertEqual(json(worker, "posted[0].roster"), #"["Nihal"]"#)
        XCTAssertEqual(json(worker, "reloads"), "0", "a call was open a moment ago")

        worker.evaluateScript("now += 61000; fireTimers();")
        XCTAssertEqual(json(worker, "reloads"), "1")
    }

    func testAnUpdateThatLandsBetweenCallsIsFoundWhileIdle() throws {
        let worker = try context(chromeAPIs, script: "service-worker.js")
        worker.evaluateScript("onDisk = '1.3.0'; now += 600000; intervals.forEach(function (f) { f(); });")

        XCTAssertEqual(json(worker, "reloads"), "1")
    }
}
#endif
