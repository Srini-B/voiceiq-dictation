#if os(macOS)
import AppKit
import ApplicationServices
import CoreAudio

/// Polls for an active call. A call is "active" when:
/// - a known calling app, or a browser showing a meeting page, is itself
///   capturing the microphone;
/// - the system call daemons capture it (FaceTime, iPhone calls on the Mac);
/// - any other app, or browser page, both captures the microphone and plays
///   sound: two-way audio is what a call looks like, whatever app makes it.
/// Mic use is read per process (macOS 14.2+ Core Audio process objects), so
/// VoiceiQ's own recording never counts as a call and a call that ends while
/// the app stays open is still noticed. Two consecutive hits start, three misses stop.
@MainActor public final class CallDetector {
    public var onChange: ((CallSource?) -> Void)?
    private var timer: Timer?, hits = 0, misses = 0
    private var active: CallSource?

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
            let source = await Task.detached(priority: .utility) { Self.detectedSource() }.value
            guard let self else { return }
            self.polling = false
            if source != nil {
                self.hits += 1; self.misses = 0
                if self.active == nil, self.hits >= 2 { self.active = source; self.onChange?(source) }
            } else {
                self.misses += 1; self.hits = 0
                if self.active != nil, self.misses >= 3 { self.active = nil; self.onChange?(nil) }
            }
        }
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
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return nil }
        var result = Audio()
        for object in objects {
            let input = flag(object, kAudioProcessPropertyIsRunningInput), output = flag(object, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { continue }
            var pids: [pid_t] = []
            var pid: pid_t = 0; var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 {
                pids.append(pid)
                if input { result.directInputPIDs.insert(pid) }
                if let owner = Self.responsiblePID?(pid), owner > 0 { pids.append(owner) }
                if input, callDaemon(pid) { result.inputDaemon = true }
            }
            var value: Unmanaged<CFString>? = nil; var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundle = Self.address(kAudioProcessPropertyBundleID)
            let id = AudioObjectGetPropertyData(object, &bundle, 0, nil, &valueSize, &value) == noErr
                ? value?.takeRetainedValue() as String? : nil
            if input { result.inputPIDs.formUnion(pids); if let id { result.inputBundleIDs.insert(id) } }
            if output { result.outputPIDs.formUnion(pids); if let id { result.outputBundleIDs.insert(id) } }
        }
        return result
    }

    private nonisolated static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.address(selector)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private nonisolated static func callDaemon(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return CallApps.callDaemons.contains((String(cString: buffer) as NSString).lastPathComponent)
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

    private nonisolated static func detectedSource() -> CallSource? {
        let audio = runningAudio()
        // Pre-14.2: only a global "mic is in use" bit exists. VoiceiQ's own meeting
        // tap trips it, so there the call ends only when the app or tab goes away,
        // and only known apps and meeting pages count.
        if audio == nil, !microphoneInUse() { return nil }
        if audio?.inputDaemon == true { return CallApps.callDaemonSource }
        let own = Bundle.main.bundleIdentifier ?? "io.blue.voiceiq"
        // An app on the mic itself comes before one only responsible for it: a
        // call app launched from a terminal has the terminal as its owner.
        let apps = NSWorkspace.shared.runningApplications.sorted {
            (audio?.directInputPIDs.contains($0.processIdentifier) ?? false) && !(audio?.directInputPIDs.contains($1.processIdentifier) ?? false)
        }
        for app in apps {
            guard let id = app.bundleIdentifier, !id.hasPrefix(own) else { continue }
            let pid = app.processIdentifier
            let capturing = audio.map { $0.inputPIDs.contains(pid) || $0.inputBundleIDs.contains { $0.hasPrefix(id) } } ?? true
            guard capturing else { continue }
            let playing = audio.map { $0.outputPIDs.contains(pid) || $0.outputBundleIDs.contains { $0.hasPrefix(id) } } ?? false
            if let name = CallApps.known[id] { return .app(bundleID: id, name: name) }
            let isBrowser = CallApps.browsers.contains(id) || app.localizedName?.localizedCaseInsensitiveContains("Chrome") == true
                || app.localizedName?.localizedCaseInsensitiveContains("Chromium") == true
            if isBrowser {
                let page = BrowserPages.read(pid: pid)
                if let match = page.meeting { return .browser(bundleID: id, host: match) }
                if playing, !page.excluded { return .browser(bundleID: id, host: page.host ?? app.localizedName ?? id) }
            } else if playing, !CallApps.notCalls.contains(id) {
                return .app(bundleID: id, name: app.localizedName ?? id)
            }
        }
        return nil
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

/// The pages a browser shows, read through the Accessibility API.
enum BrowserPages {
    struct Page {
        /// The matching entry of `CallApps.meetingPages`, or the page's host when a URL matched.
        var meeting: String?
        /// The front page's host, when a URL could be read.
        var host: String?
        /// The front page is one `CallApps.notCallPages` lists.
        var excluded = false
    }

    /// Window titles, plus the URL of each window's web area: titles can be
    /// anything a page sets, the URL is where the tab is. Chrome and Safari put
    /// the web area several levels below the window, so the search is bounded.
    static func read(pid: pid_t) -> Page {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return Page() }
        var page = Page()
        for window in windows {
            var strings: [String] = []
            for key in [kAXTitleAttribute as String, kAXDocumentAttribute as String, "AXURL"] {
                if let string = value(window, key) as? String { strings.append(string) }
            }
            let url = webAreaURL(window)
            if let url { strings.append(url.absoluteString) }
            // Windows come front to back: the first page with an address is the one in front.
            if page.host == nil, let host = url?.host() {
                page.host = host.replacingOccurrences(of: "www.", with: "")
                page.excluded = CallApps.notCallPages.contains { host.hasSuffix($0) }
            }
            if let match = CallApps.meetingPages.first(where: { needle in strings.contains { $0.localizedCaseInsensitiveContains(needle) } }) {
                page.meeting = url.flatMap { $0.absoluteString.localizedCaseInsensitiveContains(match) ? $0.host() : nil } ?? match
                return page
            }
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
