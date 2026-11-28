#if os(macOS)
import AppKit
import ApplicationServices
import CoreAudio

/// Polls for an active call. A call is "active" when:
/// - a known calling app is itself capturing the microphone;
/// - a browser shows a meeting page and captures the microphone, or shows a
///   joined call room in front and plays sound: an owner who joined muted
///   can hold no microphone at all;
/// - the system call daemons capture it (FaceTime, iPhone calls on the Mac);
/// - a browser page both captures the microphone and plays sound: two-way
///   audio in a tab is what a call on a site not listed looks like.
/// Any other app on the microphone is not a call, however it uses it:
/// recorders, dictation, remote desktop clients, and virtual machines play
/// and capture too. Mic use is read per process (macOS 14.2+ Core Audio
/// process objects), so VoiceiQ's own recording never counts as a call and a
/// call that ends while the app stays open is still noticed. Two consecutive
/// hits on the same call start or replace the offer, three misses stop it.
@MainActor public final class CallDetector {
    public var onChange: ((CallSource?) -> Void)?
    private var timer: Timer?, hits = 0, misses = 0
    private var active: CallSource?, candidate: CallSource?
    /// The active call came from a known app, a call daemon, or a meeting page,
    /// not only from a tab that looked like one.
    private var activeConfirmed = false

    public init() {}
    public func start() { stop(); poll(); timer = .scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } } }
    public func stop() { timer?.invalidate(); timer = nil; hits = 0; misses = 0 }

    private var polling = false

    /// The Core Audio process walk and the AX window reads take up to
    /// ~100 ms and block on the inspected app, so they run off the main actor;
    /// only the hit/miss bookkeeping runs here.
    private func poll() {
        guard !polling else { return }
        polling = true
        Task { [weak self] in
            let continuing = self?.active
            let found = await Task.detached(priority: .utility) { Self.detectedSource(continuing: continuing) }.value
            guard let self else { return }
            self.polling = false
            let source = found?.0, confirmed = found?.confirmed ?? false
            self.hits = source != nil && source == self.candidate ? self.hits + 1 : (source == nil ? 0 : 1)
            self.candidate = source
            // Misses count polls without the active call, even when another
            // source shows, so a call that ended gives way to the next one. A
            // browser call, meeting page or look-alike, stays the same call
            // while that browser plays and captures with no meeting page in
            // front: the page read follows the front tab, the audio is the
            // whole browser's.
            if let active = self.active {
                let continues = source == active || (!confirmed && Self.app(of: source) == Self.app(of: active))
                self.misses = continues ? 0 : self.misses + 1
                if self.misses >= 3 { self.active = nil; self.activeConfirmed = false; self.onChange?(nil) }
            }
            // A confirmed call (known app, call daemon, meeting page) also
            // replaces a look-alike that is still there.
            if let source, self.hits >= 2, source != self.active, self.active == nil || (confirmed && !self.activeConfirmed) {
                self.active = source; self.activeConfirmed = confirmed; self.misses = 0; self.onChange?(source)
            }
        }
    }

    private static func app(of source: CallSource?) -> String? {
        switch source { case let .app(id, _), let .browser(id, _): return id; case nil: return nil }
    }

    /// Processes with running audio. Browsers capture from helper processes
    /// (Chrome's `.helper`, Safari's `com.apple.WebKit.GPU` XPC service), so
    /// both the responsible app's pid and the helper's bundle ID are kept.
    /// Nil when the per-process API is unavailable (pre-14.2).
    private struct Audio {
        var inputPIDs = Set<pid_t>(), outputPIDs = Set<pid_t>()
        /// Processes that capture themselves, not through a helper they are responsible for.
        var directInputPIDs = Set<pid_t>()
        var inputBundleIDs = Set<String>(), outputBundleIDs = Set<String>()
        var inputDaemon = false
    }

    private nonisolated static func runningAudio() -> Audio? {
        guard #available(macOS 14.2, *) else { return nil }
        guard let processes = objects(system, kAudioHardwarePropertyProcessObjectList) else { return nil }
        var result = Audio()
        for object in processes {
            let input = flag(object, kAudioProcessPropertyIsRunningInput), output = flag(object, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { continue }
            var pids: [pid_t] = []
            if let pid = pid(of: object) {
                pids.append(pid)
                if let owner = Self.responsiblePID?(pid), owner > 0 { pids.append(owner) }
            }
            let id = string(object, kAudioProcessPropertyBundleID)
            if input, let pid = pids.first {
                result.directInputPIDs.insert(pid)
                if callDaemon(pid) { result.inputDaemon = true }
            }
            if input { result.inputPIDs.formUnion(pids); if let id { result.inputBundleIDs.insert(id) } }
            if output { result.outputPIDs.formUnion(pids); if let id { result.outputBundleIDs.insert(id) } }
        }
        return result
    }

    private nonisolated static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Nil when Core Audio fails the read; an empty list is a successful read.
    private nonisolated static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return nil }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// The Core Audio processes behind `source`: the app, every helper it is
    /// responsible for (Chrome's audio service, Safari's WebKit GPU process),
    /// and for FaceTime and the phone the call daemons that carry the audio.
    /// Read from the process list, so the speakers, headphones, or AirPods the
    /// call plays to make no difference. Nil when none of them has audio open,
    /// and before macOS 14.2.
    public nonisolated static func processes(for source: CallSource) -> CallProcesses? {
        guard #available(macOS 14.2, *), let list = objects(system, kAudioHardwarePropertyProcessObjectList) else { return nil }
        let bundleID: String
        switch source { case let .app(id, _), let .browser(id, _): bundleID = id }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let appPIDs = Set(apps.map(\.processIdentifier))
        let appPaths = Set(apps.compactMap { $0.bundleURL?.standardizedFileURL.path })
        let viaDaemons = CallApps.daemonCallApps.contains(bundleID)
        var matched: [AudioObjectID] = [], input: AudioDeviceID?, running = false, capturing = false
        for object in list {
            guard let pid = pid(of: object), pid != getpid() else { continue }
            let owner = responsiblePID?(pid)
            let ours = appPIDs.contains(pid) || owner.map(appPIDs.contains) == true
                || string(object, kAudioProcessPropertyBundleID).map { $0 == bundleID || $0.hasPrefix(bundleID + ".helper") } == true
                || (viaDaemons && callDaemon(pid))
                // A helper inside the app's bundle, as detection attributes it.
                || executablePath(pid).flatMap(containingBundle).map(appPaths.contains) == true
            guard ours else { continue }
            matched.append(object)
            let objectInput = flag(object, kAudioProcessPropertyIsRunningInput)
            capturing = capturing || objectInput
            running = running || objectInput || flag(object, kAudioProcessPropertyIsRunningOutput)
            // A process can list output-only devices (the built-in speakers)
            // here; the mic track must never follow one. From Hex (`657aa0cf`).
            if input == nil, objectInput,
               let devices = objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) {
                input = firstInput(devices, inputChannels: Self.inputChannels)
            }
        }
        return matched.isEmpty ? nil : CallProcesses(objects: matched, inputDevice: input, isRunningAudio: running,
                                                     isRunningInput: capturing)
    }

    /// The first of `devices` that has input channels.
    nonisolated static func firstInput(_ devices: [AudioDeviceID], inputChannels: (AudioDeviceID) -> UInt32) -> AudioDeviceID? {
        devices.first { inputChannels($0) > 0 }
    }

    /// The input channels `device` offers; 0 for an output-only device or one Core Audio will not describe.
    private nonisolated static func inputChannels(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }

    /// The screen is locked, or another user's session has the console.
    /// `CGSSessionScreenIsLocked` is undocumented and absent while unlocked.
    public nonisolated static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true || (session["kCGSSessionOnConsoleKey"] as? Bool) == false
    }

    private nonisolated static func pid(of process: AudioObjectID) -> pid_t? {
        var pid: pid_t = 0, size = UInt32(MemoryLayout<pid_t>.size)
        var address = Self.address(kAudioProcessPropertyPID)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr && pid > 0 ? pid : nil
    }

    private nonisolated static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = Self.address(selector)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value?.takeRetainedValue() as String? : nil
    }

    private nonisolated static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.address(selector)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private nonisolated static func callDaemon(_ pid: pid_t) -> Bool {
        executablePath(pid).map { CallApps.callDaemons.contains(($0 as NSString).lastPathComponent) } ?? false
    }

    private nonisolated static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return (String(cString: buffer) as NSString).standardizingPath
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Maps an XPC helper (parent launchd) back to the app it works for. Same
    /// lookup TCC uses to attribute mic access; absent on some systems, hence optional.
    private nonisolated static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The call, and whether it is confirmed rather than a browser that only looks like one.
    /// `continuing` is the call already offered or recording.
    private nonisolated static func detectedSource(continuing: CallSource?) -> (CallSource, confirmed: Bool)? {
        let audio = runningAudio()
        // Pre-14.2: only a global "mic is in use" bit exists. VoiceiQ's own meeting
        // tap trips it, so there the call ends only when the app or tab goes away,
        // and only known apps and meeting pages count.
        if audio == nil, !microphoneInUse() { return nil }
        if audio?.inputDaemon == true { return (CallApps.callDaemonSource, true) }
        let own = Bundle.main.bundleIdentifier ?? "io.blue.voiceiq"
        // An app on the mic itself comes before one only responsible for it: a
        // call app launched from a terminal has the terminal as its owner.
        let running = NSWorkspace.shared.runningApplications
        let apps = running.sorted {
            (audio?.directInputPIDs.contains($0.processIdentifier) ?? false) && !(audio?.directInputPIDs.contains($1.processIdentifier) ?? false)
        }
        var lookalike: CallSource?, seen = Set<pid_t>()
        for process in apps {
            // WebKit's XPC services are listed as apps ("Safari Graphics and
            // Media") and capture the mic themselves, so they would sort first
            // and hide the browser. The app responsible for them is the call;
            // without that lookup the helper is all there is to find.
            guard let processID = process.bundleIdentifier,
                  !(processID.hasPrefix("com.apple.WebKit.") && Self.responsiblePID != nil),
                  let app = containingApp(of: process, in: running), let id = app.bundleIdentifier, !id.hasPrefix(own),
                  seen.insert(app.processIdentifier).inserted else { continue }
            let pids = [process.processIdentifier, app.processIdentifier]
            let capturing = audio.map { a in pids.contains(where: a.inputPIDs.contains) || a.inputBundleIDs.contains { $0.hasPrefix(id) } } ?? true
            let playing = audio.map { a in pids.contains(where: a.outputPIDs.contains) || a.outputBundleIDs.contains { $0.hasPrefix(id) } } ?? false
            guard capturing || playing else { continue }
            if let name = CallApps.known[id] {
                guard capturing else { continue }
                if audio == nil || playing || !CallApps.voiceNoteApps.contains(id) { return (.app(bundleID: id, name: name), true) }
                continue
            }
            let name = app.localizedName ?? id
            guard CallApps.browsers.contains(id) || name.localizedCaseInsensitiveContains("Chrome")
                    || name.localizedCaseInsensitiveContains("Chromium") else { continue }
            // A joined call room in front that only plays counts: an owner who
            // joined muted can hold no mic at all (the live-call probe's owner,
            // 2026-11-28). The sound is the whole browser's, so a room in a back
            // window does not start a call (Codex on #138), and a browser that
            // only plays (music, video) has only its front window read. The call
            // already offered stays while its browser plays and any window shows
            // that page, so a muted owner can switch tabs, and only that page:
            // a chat page in front does not take the call over (Neon on #138).
            var held: String?
            if case let .browser(bundleID, host) = continuing, bundleID == id, !capturing { held = host }
            let page = BrowserPages.read(pid: app.processIdentifier, frontOnly: !capturing && held == nil, seeking: held)
            if let match = page.meeting, capturing || page.room || match == held { return (.browser(bundleID: id, host: match), true) }
            if capturing, playing, !page.excluded, lookalike == nil { lookalike = .browser(bundleID: id, host: page.host ?? name) }
        }
        return lookalike.map { ($0, false) }
    }

    /// The app a process belongs to. A helper inside another app's bundle
    /// (Chrome's "Google Chrome Helper", Granola's "Granola Helper
    /// (MacOSMicAppsWithDevices)") is that app: the app is what the lists
    /// match and what the offer names. Nil for a helper whose app is not running.
    private nonisolated static func containingApp(of process: NSRunningApplication, in running: [NSRunningApplication]) -> NSRunningApplication? {
        guard let path = process.bundleURL?.standardizedFileURL.path, let app = containingBundle(path) else { return process }
        return running.first { $0.bundleURL?.standardizedFileURL.path == app }
    }

    /// The outermost app bundle that `path` sits inside; nil for a top-level app.
    nonisolated static func containingBundle(_ path: String) -> String? {
        guard let end = path.range(of: ".app/")?.lowerBound else { return nil }
        return String(path[..<end]) + ".app"
    }

    private nonisolated static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(), size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0; size = UInt32(MemoryLayout.size(ofValue: running))
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// The Core Audio side of the call being recorded: the processes whose sound
/// the system track records, and the input device the call captures, which
/// the mic track follows.
public struct CallProcesses: Equatable, Sendable {
    public var objects: [AudioObjectID]
    public var inputDevice: AudioDeviceID?
    /// Any of them plays or captures sound now. A call that ended lets go of both.
    public var isRunningAudio = false
    /// Any of them captures sound now.
    public var isRunningInput = false

    /// Whether the call still counts as going. A browser can keep its output
    /// open after its call while the Mac is locked, so then only its
    /// microphone counts. A call app keeps its output counting: some let go
    /// of the microphone on mute. From Hex (anomalyco/hex `092a9b33`).
    public func isLive(locked: Bool, browser: Bool) -> Bool {
        locked && browser ? isRunningInput : isRunningAudio
    }
}

/// The pages a browser shows, read through the Accessibility API.
enum BrowserPages {
    struct Page {
        /// The matching entry of `CallApps.meetingPages`, or the page's host when a URL matched.
        var meeting: String?
        /// The front page's host, when a URL could be read.
        var host: String?
        /// The front page is one `CallApps.notCallPages` lists.
        var excluded = false
        /// The front page is a joined call room (`CallApps.isCallRoom`).
        var room = false
    }

    /// Window titles, plus the URL of each window's web area: titles can be
    /// anything a page sets, the URL is where the tab is. Chrome and Safari put
    /// the web area several levels below the window, so the search is bounded.
    /// `frontOnly` stops after the front page; `seeking` takes only the
    /// meeting page of that name, in any window.
    static func read(pid: pid_t, frontOnly: Bool = false, seeking: String? = nil) -> Page {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return Page() }
        var page = Page(), addressed = false
        for window in windows {
            let titles = [value(window, kAXTitleAttribute as String) as? String].compactMap { $0 }
            var addresses = [kAXDocumentAttribute as String, "AXURL"].compactMap { value(window, $0) as? String }
            let url = webAreaURL(window)
            if let url { addresses.append(url.absoluteString) }
            let strings = titles + addresses
            // Windows come front to back: the first page with an address is the
            // one in front; a picture-in-picture or popup window has none.
            if !addressed, !addresses.isEmpty { addressed = true; page.room = CallApps.isCallRoom(addresses: addresses) }
            if page.host == nil, let host = url?.host() {
                page.host = host.replacingOccurrences(of: "www.", with: "")
                page.excluded = CallApps.notCallPages.contains { host.hasSuffix($0) }
            }
            if let match = CallApps.meetingPages.first(where: { needle in strings.contains { $0.localizedCaseInsensitiveContains(needle) } }) {
                let name = CallApps.meetingName(match: match, in: strings)
                if seeking == nil || name == seeking { page.meeting = name; break }
            }
            if frontOnly, addressed { break }
        }
        // No address could be read, in any attribute (Codex on #138): the front window's title is all there is.
        if !addressed, let title = windows.first.flatMap({ value($0, kAXTitleAttribute as String) as? String }) {
            page.room = CallApps.isCallRoom(titles: [title])
        }
        return page
    }

    private static func webAreaURL(_ window: AXUIElement) -> URL? {
        var queue = [(window, 0)], visited = 0
        while !queue.isEmpty, visited < 300 {
            let (element, depth) = queue.removeFirst(); visited += 1
            if value(element, kAXRoleAttribute) as? String == "AXWebArea" {
                if let url = value(element, "AXURL") as? URL { return url }
                if let string = value(element, "AXURL") as? String { return URL(string: string) }
            }
            guard depth < 9, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue += children.prefix(24).map { ($0, depth + 1) }
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
}
#endif
