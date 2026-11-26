#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Reads the screen while the user speaks: the frontmost window at the start
/// and after each app switch, as text from Vision OCR. Only that window, so
/// other apps on the display (a password manager, a chat) are never read.
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
    private var readTasks: [Task<Void, Never>] = []
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
        // A capture still being read at key-up is left out; stop its OCR so it
        // does not compete with the dictation.
        readTasks.forEach { $0.cancel() }
        readTasks = []
        return texts
    }

    private func capture() {
        guard isRunning, Self.mayRead() else { return }
        guard let windowID = Self.frontmostWindowID() else { return }
        let pixelsPerPoint = NSScreen.main?.backingScaleFactor ?? 2
        let maxDimension = CGFloat(maxDimension)
        let vocabulary = vocabulary

        readTasks.append(Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard !Task.isCancelled,
                      let window = content.windows.first(where: { $0.windowID == windowID }) else { return }
                // OCR reads small text only at the display's own pixels.
                let longest = max(window.frame.width, window.frame.height) * pixelsPerPoint
                let scale = pixelsPerPoint * min(1, maxDimension / max(1, longest))
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: configuration
                )
                // Checked again: the app in front can change during the awaits.
                guard !Task.isCancelled, Self.mayRead(), Self.frontmostWindowID() == windowID else { return }
                let started = Date()
                let text = await ScreenText.read(image, vocabulary: vocabulary)
                guard !Task.isCancelled, let self, self.isRunning, !text.isEmpty else { return }
                self.append(text)
                Log.screen.info("read screen context (\(text.count, privacy: .public) characters in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms, \(self.texts.count, privacy: .public) kept)")
            } catch is CancellationError {
            } catch {
                Log.screen.info("screen context capture failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    /// Never a password field's screen, a password manager, or VoiceiQ itself.
    private static func mayRead() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !SecureInput.isActive, !(front.map(passwordManagers.contains) ?? false) else {
            Log.screen.info("screen context skipped: secure input or a password manager is in front")
            return false
        }
        return front != Bundle.main.bundleIdentifier
    }

    private static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.Passwords",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop", "com.apple.keychainaccess",
    ]

    private func append(_ text: String) {
        if texts.count >= maxCaptures {
            texts.remove(at: texts.count == 1 ? 0 : 1)
        }
        texts.append(text)
    }

    /// The frontmost app's front window, the one being dictated into.
    private static func frontmostWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Layer 0, visible and big enough to be a document, not a helper window.
        return windows.first(where: {
            let bounds = $0[kCGWindowBounds as String] as? [String: CGFloat]
            return ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
                && (bounds?["Width"] ?? 0) >= 200 && (bounds?["Height"] ?? 0) >= 100
        })?[kCGWindowNumber as String].flatMap { ($0 as? NSNumber)?.uint32Value }
    }
}

enum ScreenText {
    /// The screen's text, one line per recognised line, top to bottom.
    /// Accurate recognition needs the Neural Engine; where it fails (a
    /// virtual Mac), the fast recognizer reads it instead. Cancelling the
    /// calling task cancels the recognition.
    static func read(_ image: CGImage, vocabulary: [String]) async -> String {
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            nonisolated(unsafe) let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            request.customWords = vocabulary
            let read = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) {
                    (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil
                }.value
            } onCancel: {
                request.cancel()
            }
            guard !Task.isCancelled else { return "" }
            guard read else { continue }
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
