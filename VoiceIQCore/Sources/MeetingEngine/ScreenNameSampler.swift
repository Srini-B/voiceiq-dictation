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
    /// With no source: the apps the call being joined runs in, besides a
    /// browser. Nil reads any call app.
    private let joining: Set<String>?
    private var snapshots = false
    private let samples = OSAllocatedUnfairLock(initialState: [ScreenNameSample]())
    private var task: Task<Void, Never>?

    /// `source` is the call app or browser, when one was detected. With none,
    /// the frontmost known call app is read, or with `joining` (Join and
    /// Record) the frontmost of those apps or a browser meeting tab, so
    /// another call app left open is not read; with none of them, nothing is.
    public init(source: CallSource?, joining: Set<String>? = nil) {
        switch source {
        case let .app(bundleID, _), let .browser(bundleID, _): self.bundleID = bundleID
        case nil: bundleID = nil
        }
        self.joining = joining
    }

    public func start() {
        // A meeting never raises a permission prompt; the dictation onboarding
        // asks for Screen Recording and Accessibility. Either one is enough.
        snapshots = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
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
        if pid == nil, accessibility,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            pid = app.processIdentifier
            AccessibilityWaker.wakeIfNeeded(bundleID: bundleID, pid: app.processIdentifier)
        }
        return snapshots || pid != nil
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
        let out = samples.withLock { $0 }
        Log.meeting.info("screen names: \(out.count, privacy: .public) snapshots, \(out.filter { !$0.names.isEmpty }.count, privacy: .public) with names")
        return out
    }

    private func sample() async {
        let time = Date().timeIntervalSince(startedAt)
        do {
            var lines = snapshots ? try await capture().map(Self.read) ?? [] : []
            if let pid { lines += CallWindowText.lines(pid: pid) }
            let names = ScreenSpeakerNames.candidates(in: lines), me = ScreenSpeakerNames.owner(in: lines)
            let single = ScreenSpeakerNames.singleNames(in: lines)
            samples.withLock { $0.append(ScreenNameSample(time: time, names: names, me: me.isEmpty ? nil : me,
                                                          single: single.isEmpty ? nil : single,
                                                          count: ScreenSpeakerNames.participantCount(in: lines))) }
        } catch is CancellationError {
        } catch {
            Log.meeting.info("screen names snapshot failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The call's own window, read even while other windows cover it (a shared
    /// screen, a document the user works in). Never the whole display: other
    /// apps' names (a dictation app, a chat, a document) are not the meeting's.
    /// Nil when the call has no window to read, a minimized one say.
    private func capture() async throws -> CGImage? {
        guard let bundleID else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width >= 320 }
        // A browser has other windows; the meeting tab's title says which one
        // is the call, and with no such title none is.
        let meeting = windows.filter { window in CallApps.meetingPages.contains { window.title?.localizedCaseInsensitiveContains($0) == true } }
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
