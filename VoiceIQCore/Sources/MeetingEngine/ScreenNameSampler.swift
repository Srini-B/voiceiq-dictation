#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Vision

/// Reads name tags off the screen every few seconds while a meeting records.
///
/// Each snapshot is read with on-device text recognition and dropped at once;
/// it is never written to disk or sent anywhere. Only the name-like text and
/// its time are kept, for `ScreenSpeakerNames` to match against the speakers
/// once the transcript exists.
public final class ScreenNameSampler: @unchecked Sendable {
    static let interval: Duration = .seconds(3)
    /// Longest snapshot side read, in pixels. Name tags stay legible and a 5K
    /// display does not cost four times as much.
    static let maxPixels: CGFloat = 2560

    private let startedAt = Date()
    private let bundleID: String?
    private let samples = OSAllocatedUnfairLock(initialState: [ScreenNameSample]())
    private var task: Task<Void, Never>?

    /// `source` is the call app or browser, when one was detected; its largest
    /// window is read even when other windows cover it. Otherwise the main display.
    public init(source: CallSource?) {
        switch source {
        case let .app(bundleID, _), let .browser(bundleID, _): self.bundleID = bundleID
        case nil: bundleID = nil
        }
    }

    public func start() {
        // A meeting never raises the permission prompt; the dictation
        // onboarding asks for Screen Recording.
        guard CGPreflightScreenCaptureAccess() else {
            Log.meeting.info("screen names off: no Screen Recording access")
            return
        }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: Self.interval)
            }
        }
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
            let image = try await capture()
            let names = ScreenSpeakerNames.candidates(in: try Self.read(image))
            samples.withLock { $0.append(ScreenNameSample(time: time, names: names)) }
        } catch is CancellationError {
        } catch {
            Log.meeting.info("screen names snapshot failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func capture() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        if let bundleID, let window = content.windows
            .filter({ $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width >= 320 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
            // VoiceiQ's own windows hold transcripts full of names; they are not the meeting.
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        } else {
            throw CocoaError(.featureUnsupported)
        }
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
