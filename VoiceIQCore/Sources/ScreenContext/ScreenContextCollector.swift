#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Reads the screen while the user speaks: the display under the frontmost
/// window at the start and after each app switch, as text from Vision OCR.
/// The OCR runs during the recording, so key-up does not wait for it; a
/// capture still being read at key-up is left out. Text replaced screenshots
/// because any image attached to the dictation call made gemini-3.8-flash
/// think on almost every call (2026-11-26).
@MainActor
public final class ScreenContextCollector {
    public private(set) var texts: [String] = []

    private let maxCaptures: Int
    private let maxDimension: Int
    private let vocabulary: [String]
    private var activationObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false

    /// `vocabulary`: Dictionary terms, so OCR spells them as listed.
    public init(maxCaptures: Int = 4, maxDimension: Int = 3200, vocabulary: [String] = []) {
        self.maxCaptures = max(1, maxCaptures)
        self.maxDimension = max(1, maxDimension)
        self.vocabulary = vocabulary
    }

    public func start() {
        guard !isRunning else { return }
        texts = []
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            Log.screen.info("screen context unavailable because Screen Recording access was denied")
            return
        }

        isRunning = true
        capture()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    self?.capture()
                }
            }
        }
    }

    public func stop() -> [String] {
        isRunning = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
        return texts
    }

    private func capture() {
        guard isRunning else { return }
        let screen = Self.frontmostDisplay()
        let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            .flatMap { $0 as? NSNumber }
            .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        let pixelsPerPoint = screen?.backingScaleFactor ?? 2
        let maxDimension = CGFloat(maxDimension)
        let vocabulary = vocabulary

        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled,
                      let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else { return }
                // OCR reads small text only at the display's own pixels.
                let longest = CGFloat(max(display.width, display.height)) * pixelsPerPoint
                let scale = pixelsPerPoint * min(1, maxDimension / longest)
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(CGFloat(display.width) * scale))
                configuration.height = max(1, Int(CGFloat(display.height) * scale))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: configuration
                )
                guard !Task.isCancelled else { return }
                let started = Date()
                let text = await Task.detached(priority: .userInitiated) {
                    ScreenText.read(image, vocabulary: vocabulary)
                }.value
                guard let self, self.isRunning, !text.isEmpty else { return }
                self.append(text)
                Log.screen.info("read screen context (\(text.count, privacy: .public) characters in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms, \(self.texts.count, privacy: .public) kept)")
            } catch is CancellationError {
            } catch {
                Log.screen.info("screen context capture failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func append(_ text: String) {
        if texts.count >= maxCaptures {
            texts.remove(at: texts.count == 1 ? 0 : 1)
        }
        texts.append(text)
    }

    private static func frontmostDisplay() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]],
              let bounds = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                      && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
              })?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"] else {
            return NSScreen.main
        }
        let center = CGPoint(x: x + width / 2, y: y + height / 2)
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let appKitCenter = CGPoint(x: center.x, y: desktopTop - center.y)
        return NSScreen.screens.first(where: { $0.frame.contains(appKitCenter) }) ?? NSScreen.main
    }
}

enum ScreenText {
    /// The screen's text, one line per recognised line, top to bottom.
    /// Accurate recognition needs the Neural Engine; where it fails (a
    /// virtual Mac), the fast recognizer reads it instead.
    static func read(_ image: CGImage, vocabulary: [String]) -> String {
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            request.customWords = vocabulary
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continue
            }
            let lines = (request.results ?? []).sorted {
                $0.boundingBox.maxY != $1.boundingBox.maxY ? $0.boundingBox.maxY > $1.boundingBox.maxY
                    : $0.boundingBox.minX < $1.boundingBox.minX
            }
            return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        return ""
    }
}
#endif
