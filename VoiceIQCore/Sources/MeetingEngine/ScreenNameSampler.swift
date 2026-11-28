#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Vision

/// Reads name tags off the screen every few seconds while a meeting records:
/// a snapshot read with on-device text recognition, plus the call app's
/// window text through the Accessibility API (`CallWindowText`).
///
/// Each snapshot is read and dropped at once; it is never written to disk or
/// sent anywhere. Only the name-like text and its time are kept, for
/// `ScreenSpeakerNames` to match against the speakers once the transcript exists.
public final class ScreenNameSampler: @unchecked Sendable {
    static let interval: Duration = .seconds(3)
    /// Longest snapshot side read, in pixels. Name tags stay legible and a 5K
    /// display does not cost four times as much.
    static let maxPixels: CGFloat = 2560

    private let startedAt = Date()
    private var bundleID: String?
    private var pid: pid_t?
    /// `pid` was picked for showing a joined call room, not only a call
    /// site's page; until then it is picked again on every tick.
    private var pidHoldsRoom = false
    private var tick = 0
    private var chromium: (pid: pid_t, isChromium: Bool)?
    /// A browser this sampler switched AXEnhancedUserInterface on in, until
    /// a read-back shows it off again. Its "on" is ours, not another tool's.
    private let pulsedPID = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
    private var switchOffTries = 0
    /// A Chromium browser's page text is read on every this-many ticks (15 s),
    /// since each read briefly makes the browser animate its window moves.
    static let browserTreeEvery = 5
    /// With no source: the apps the call being joined runs in, besides a
    /// browser. Nil reads any call app.
    private let joining: Set<String>?
    private var snapshots = false
    /// A chat site's page may be the call's window: the call was detected on
    /// one, or not detected at all (Fable on #146).
    private let chats: Bool
    private let samples = OSAllocatedUnfairLock(initialState: [ScreenNameSample]())
    private var task: Task<Void, Never>?

    /// `source` is the call app or browser, when one was detected. With none,
    /// the frontmost known call app is read, or with `joining` (Join and
    /// Record) the frontmost of those apps or a browser meeting tab, so
    /// another call app left open is not read; with none of them, nothing is.
    public init(source: CallSource?, joining: Set<String>? = nil) {
        switch source {
        case let .app(bundleID, _): self.bundleID = bundleID; chats = false
        case let .browser(bundleID, host): self.bundleID = bundleID; chats = CallApps.isChat(host: host)
        case nil: bundleID = nil; chats = true
        }
        self.joining = joining
    }

    public func start() {
        // A meeting never raises a permission prompt; the dictation onboarding
        // asks for Screen Recording and Accessibility. Either one is enough.
        snapshots = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        if accessibility { Self.endLeftoverPulse() }
        guard snapshots || accessibility else {
            Log.meeting.info("screen names off: no Screen Recording or Accessibility access")
            return
        }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                // Resolved on each tick until found: Join and Record starts
                // recording before the call app has opened its window.
                if let self, self.resolveCallApp(accessibility: accessibility) { await self.sample() }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Whether there is a call app to read. A recording started by hand, with
    /// no call detected (a call app without microphone access, or one just
    /// being opened), reads the frontmost call app once there is one.
    private func resolveCallApp(accessibility: Bool) -> Bool {
        if bundleID == nil { bundleID = Self.frontCallApp(among: joining) }
        guard let bundleID else { return false }
        // A call app relaunched mid-call is a new process (Codex on #146).
        if let held = pid, NSRunningApplication(processIdentifier: held)?.isTerminated != false { pid = nil; pidHoldsRoom = false }
        if !pidHoldsRoom, accessibility, let found = Self.callPID(bundleID: bundleID, chats: chats) {
            if pid != found.pid { switchOffTries = 0 }
            pid = found.pid; pidHoldsRoom = found.joined
            AccessibilityWaker.wakeIfNeeded(bundleID: bundleID, pid: found.pid)
        }
        return snapshots || pid != nil
    }

    /// The process that holds the call. A browser can run several instances
    /// under one bundle ID (separate profiles, the live-call probe's four
    /// Chromes), and Core Audio's tap takes all of them, so the call is the
    /// one showing a joined call room, the frontmost such, not whichever
    /// instance the system lists first. A call site's page alone (a Teams or
    /// WhatsApp chat) counts only when no instance shows a joined room, since
    /// not every site's room address is known (Codex on #146).
    /// `joined`: the pick is final, the only instance or one showing a joined room.
    static func callPID(bundleID: String, chats: Bool) -> (pid: pid_t, joined: Bool)? {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        guard pids.count > 1, CallApps.browsers.contains(bundleID) else { return pids.first.map { ($0, true) } }
        let windows = Dictionary(pids.map { ($0, CallWindowText.callWindowFrames(pid: $0, chats: chats)) }, uniquingKeysWith: { first, _ in first })
        let joined = Set(pids.filter { windows[$0]?.joined.isEmpty == false })
        let rooms = joined.isEmpty ? Set(pids.filter { windows[$0]?.pages.isEmpty == false }) : joined
        guard !rooms.isEmpty else { return nil }
        // Front to back, as `frontCallApp` reads them.
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = onScreen.lazy.filter { $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }.first(where: rooms.contains)
        return (front ?? rooms.min()).map { ($0, !joined.isEmpty) }
    }

    /// The known call app, or the browser showing a meeting page (Google Meet
    /// opened by Join and Record, say), with the frontmost normal window.
    /// `apps` limits the call apps; browsers always count.
    static func frontCallApp(among apps: Set<String>? = nil) -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var browsersRead = Set<pid_t>()
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            if CallApps.known[id] != nil, apps?.contains(id) ?? true { return id }
            guard CallApps.browsers.contains(id) else { continue }
            // Window titles need Screen Recording; without it, Accessibility
            // reads the browser's pages, once per browser.
            if let title = window[kCGWindowName as String] as? String {
                if CallApps.meetingPages.contains(where: { title.localizedCaseInsensitiveContains($0) }) { return id }
            } else if AXIsProcessTrusted(), browsersRead.insert(pid).inserted, BrowserPages.read(pid: pid).meeting != nil {
                return id
            }
        }
        return nil
    }

    /// Everything read so far, in time order.
    public func stop() -> [ScreenNameSample] {
        task?.cancel(); task = nil
        // Off the caller's thread: each AX call can wait up to 1 s on a busy Chrome.
        if let pid = pulsedPID.withLock({ $0 }) { Task.detached { _ = Self.switchOff(pid) } }
        let out = samples.withLock { $0 }
        Log.meeting.info("screen names: \(out.count, privacy: .public) snapshots, \(out.filter { !$0.names.isEmpty }.count, privacy: .public) with names")
        return out
    }

    private func sample() async {
        let time = Date().timeIntervalSince(startedAt)
        do {
            let image = snapshots ? try await capture() : nil
            var lines = try image.map(Self.read) ?? []
            // A tick that looked at nothing records nothing: an empty sample
            // counts against every name's share, and a Chromium page read only
            // every fifth tick would otherwise cap a name at 20 %, under
            // `match`'s 50 % (Codex on #146).
            var looked = image != nil
            if let pid {
                let browser = bundleID.map(CallApps.browsers.contains) ?? false
                if chromium?.pid != pid { chromium = (pid, Self.isChromium(pid)) }
                // A switch-off that timed out while Chrome built its tree is
                // retried, not mistaken for another tool's setting; after 3
                // tries, or under VoiceOver, the "on" is that tool's.
                if pulsedPID.withLock({ $0 }) == pid {
                    switchOffTries += 1
                    if Self.switchOff(pid) || switchOffTries >= 3 || NSWorkspace.shared.isVoiceOverEnabled {
                        pulsedPID.withLock { $0 = nil }
                        UserDefaults.standard.removeObject(forKey: Self.pulsedKey)
                    }
                }
                let ours = pulsedPID.withLock { $0 } == pid
                if browser, chromium?.isChromium == true, ours || Self.webTreeIsOpen(pid) == false {
                    if tick % Self.browserTreeEvery == 0 {
                        // The snapshot first, so samples stay in time order.
                        if looked { record(lines, at: time); looked = false }
                        pulsedPID.withLock { $0 = pid }; switchOffTries = 0
                        let page = await Self.whileWebTreeOpen(pid) { CallWindowText.lines(pid: pid, browser: true, chats: chats) }
                        // Its own sample, stamped when it was read (before a
                        // switch-off that can wait 2 s), about 3 s after the
                        // snapshot: `match` pairs by time (agy on #146).
                        let readAt = Date().timeIntervalSince(startedAt)
                        if Self.switchOff(pid) { pulsedPID.withLock { $0 = nil } }
                        if !Task.isCancelled { record(page, at: readAt) }
                    }
                    // Page text counts only at the time it was read: carried to
                    // later ticks, an active-speaker tile's old name lands on the
                    // next speaker's turn, and `match` pairs names with voices by
                    // time (Codex on #146). A name only the page shows (not a
                    // tile) therefore has a lower share when snapshots also run.
                } else {
                    lines += CallWindowText.lines(pid: pid, browser: browser, chats: chats)
                    looked = true
                }
            }
            tick += 1
            if looked { record(lines, at: time) }
        } catch is CancellationError {
        } catch {
            Log.meeting.info("screen names snapshot failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func record(_ lines: [String], at time: TimeInterval) {
        let names = ScreenSpeakerNames.candidates(in: lines), me = ScreenSpeakerNames.owner(in: lines)
        let single = ScreenSpeakerNames.singleNames(in: lines), count = ScreenSpeakerNames.participantCount(in: lines)
        samples.withLock { $0.append(ScreenNameSample(time: time, names: names, me: me.isEmpty ? nil : me,
                                                      single: single.isEmpty ? nil : single, count: count)) }
    }

    /// Chrome opens its web pages' accessibility tree only while
    /// AXEnhancedUserInterface is on; AXManualAccessibility, which
    /// `AccessibilityWaker` sets, returns -25205 and opens nothing. MEASURED
    /// 2026-11-28 on the Mac mini, Chrome on vdo.ninja from a cold start:
    /// 55 elements and no names until it is set; 161 with the three name
    /// tags 2 s after; 55 again the moment it is set back to false, which
    /// also stops the window-move animation it causes. So the read happens
    /// with it on, and it is always switched off after, even on cancel. When
    /// something else already keeps it on (VoiceOver, Voice Control, a window
    /// manager), the tree is open and is read on every tick without touching
    /// it (`webTreeIsOpen`), so their view of Chrome never changes (agy on #146).
    /// The caller switches it off (`switchOff`) and confirms it.
    static func whileWebTreeOpen(_ pid: pid_t, read: () -> [String]) async -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // A crash inside the pulse would leave Chrome animating; the next sampler switches it off.
        UserDefaults.standard.set(Int(pid), forKey: pulsedKey)
        AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(2500))
        guard !Task.isCancelled else { return [] }
        return read()
    }

    /// Sets it back to false; true once a read-back shows it off, the
    /// browser cannot report it at all, or it has quit. Chrome returns an
    /// error code even for a write that works (-25208), so only the
    /// read-back says; a write or read that times out while Chrome builds the
    /// tree it just opened keeps the pulse ours, to retry (agy, Codex on #146).
    static func switchOff(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanFalse)
        var value: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, enhancedUI, &value)
        let off = read == .success ? (value as? Bool) != true
            : read == .attributeUnsupported || read == .noValue || NSRunningApplication(processIdentifier: pid) == nil
        if off { UserDefaults.standard.removeObject(forKey: pulsedKey) }
        return off
    }

    /// Nil when the read fails or times out: the setting may be another
    /// tool's, and a pulse would switch it off under them (Fable on #146).
    static func webTreeIsOpen(_ pid: pid_t) -> Bool? {
        if NSWorkspace.shared.isVoiceOverEnabled { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, enhancedUI, &value) {
        case .success: return (value as? Bool) == true
        case .attributeUnsupported, .noValue: return false
        default: return nil
        }
    }

    /// Switches off a pulse a crashed or quit app left on, if that browser
    /// still runs. Called at launch, off the main thread since Chrome can take
    /// up to the 1 s timeout to answer, and when a sampler starts.
    public static func endLeftoverPulse() {
        let pid = pid_t(UserDefaults.standard.integer(forKey: pulsedKey))
        guard pid > 0 else { return }
        UserDefaults.standard.removeObject(forKey: pulsedKey)
        // The pid may now be another app's; under VoiceOver the tree stays open anyway.
        guard isChromium(pid), !NSWorkspace.shared.isVoiceOverEnabled else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanFalse)
    }

    // Computed: a stored static CFString is not Sendable under Swift 6.
    private static var enhancedUI: CFString { "AXEnhancedUserInterface" as CFString }
    private static let pulsedKey = "screenNamesPulsedBrowserPID"

    static func isChromium(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleURL.map { !TypingInserter.chromiumMajorVersions(in: $0).isEmpty } == true
    }

    /// The call's own window, read even while other windows cover it (a shared
    /// screen, a document the user works in). Never the whole display: other
    /// apps' names (a dictation app, a chat, a document) are not the meeting's.
    /// Nil when the call has no window to read, a minimized one say.
    private func capture() async throws -> CGImage? {
        guard let bundleID else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let windows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID && window.windowLayer == 0 && window.frame.width >= 320
                && pid.map { window.owningApplication?.processID == $0 } ?? true
        }
        // A browser has other windows; the call is the one whose tab is a call
        // page. Its title is the page's own ("Owner" on vdo.ninja), so the
        // address read through Accessibility says which, matched by frame;
        // without Accessibility only a title naming the site can. A joined
        // room wins over the same app's call-site pages, which include chats
        // (Codex on #146).
        let known: (joined: [CallWindow], pages: [CallWindow]) = pid.map { CallWindowText.callWindowFrames(pid: $0, chats: chats) } ?? (joined: [], pages: [])
        // Same frame within 2 pt; of two windows with one frame (both zoomed),
        // the one whose title starts the AX title.
        let matching = { (known: [CallWindow]) -> [SCWindow] in
            let near = windows.filter { window in
                known.contains { abs($0.frame.minX - window.frame.minX) < 2 && abs($0.frame.minY - window.frame.minY) < 2
                    && abs($0.frame.width - window.frame.width) < 2 && abs($0.frame.height - window.frame.height) < 2 }
            }
            guard near.count > 1 else { return near }
            let titled = near.filter { window in
                window.title.map { title in !title.isEmpty && known.contains { $0.title.hasPrefix(title) } } == true
            }
            return titled.isEmpty ? near : titled
        }
        let joined = matching(known.joined)
        let meeting = !joined.isEmpty ? joined : matching(known.pages) + windows.filter { window in
            window.title.map { title in CallApps.meetingPages.contains { title.localizedCaseInsensitiveContains($0) } } == true
        }
        let candidates = meeting.isEmpty && !CallApps.browsers.contains(bundleID) ? windows : meeting
        // On screen first (a window on another Space still counts), then the largest.
        let rank = { (window: SCWindow) in (window.isOnScreen ? 1 : 0, window.frame.width * window.frame.height) }
        guard let window = candidates.max(by: { rank($0) < rank($1) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixels = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, Self.maxPixels / max(pixels.width, pixels.height, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(pixels.width * scale))
        configuration.height = max(1, Int(pixels.height * scale))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Text lines in the image. Name tags are small, so each quarter of the
    /// frame is read on its own as well; Vision scales a region of interest up.
    static func read(_ image: CGImage) throws -> [String] {
        let regions = [CGRect(x: 0, y: 0, width: 1, height: 1),
                       CGRect(x: 0, y: 0, width: 0.55, height: 0.55), CGRect(x: 0.45, y: 0, width: 0.55, height: 0.55),
                       CGRect(x: 0, y: 0.45, width: 0.55, height: 0.55), CGRect(x: 0.45, y: 0.45, width: 0.55, height: 0.55)]
        let requests = regions.map { region in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.regionOfInterest = region
            return request
        }
        try VNImageRequestHandler(cgImage: image).perform(requests)
        var lines: [String] = []
        for request in requests {
            for observation in request.results ?? [] {
                guard let top = observation.topCandidates(1).first, top.confidence >= 0.4,
                      !lines.contains(top.string) else { continue }
                lines.append(top.string)
            }
        }
        return lines
    }
}
#endif
