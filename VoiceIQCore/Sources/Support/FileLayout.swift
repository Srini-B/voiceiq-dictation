import Foundation
import os

/// Where everything lives on disk. One folder per dictation, Superwhisper-proven
/// layout: audio.caf (crash-safe master), audio.flac (upload copy, M3+), meta.json.
public enum FileLayout {
    /// Test hook: unit tests MUST sandbox here — the suite once wrote failed-
    /// session folders straight into the user's real History.
    public static var overrideRoot: URL? {
        get { overrideRootLock.withLock { $0 } }
        set { overrideRootLock.withLock { $0 = newValue } }
    }
    private static let overrideRootLock = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public static var appSupportRoot: URL {
        if let overrideRoot { return overrideRoot }
        if let testDataFolder { return testDataFolder }
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent("VoiceiQ", isDirectory: true)
        // Folder names this app shipped under before, oldest first. The first
        // one that still exists is moved into place; later ones are left alone.
        for legacyName in ["Voice IQ", "Jot"] where !fileManager.fileExists(atPath: new.path) {
            let old = base.appendingPathComponent(legacyName, isDirectory: true)
            if fileManager.fileExists(atPath: old.path) {
                try? fileManager.moveItem(at: old, to: new)
            }
        }
        return new
    }

    /// The `DebugDataFolder` default: an absolute path a test copy of the app
    /// keeps all its data in instead of ~/Library/Application Support/VoiceiQ.
    /// The app is not sandboxed, so a copy under another bundle ID
    /// (io.blue.voiceiq.probe) otherwise writes into the real app's folder,
    /// and the real app uploads those meetings at its next launch (Codex on
    /// #140). Read once, at launch. Mac only: on iOS the app, its keyboard and
    /// its Live Activity share an App Group, so a folder of the app's own
    /// would split them. Never derived from the bundle ID, for the same reason.
    nonisolated(unsafe) public internal(set) static var testDataFolder: URL? = testDataFolder(in: .standard)

    static func testDataFolder(in defaults: UserDefaults) -> URL? {
        #if os(macOS)
        guard let path = defaults.string(forKey: "DebugDataFolder") else { return nil }
        guard path.hasPrefix("/") else {
            Log.session.error("DebugDataFolder ignored, not an absolute path: \(path, privacy: .public)")
            return nil
        }
        Log.session.notice("data folder (test): \(path, privacy: .public)")
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }

    public static var recordingsRoot: URL {
        appSupportRoot.appendingPathComponent("recordings", isDirectory: true)
    }

    public static var meetingsRoot: URL {
        appSupportRoot.appendingPathComponent("meetings", isDirectory: true)
    }

    /// Agent mode's saved runs, removed with it in 0.7.12; see
    /// `SettingsStore.removeRetiredSettingsOnce`.
    static var agentRunsRoot: URL {
        appSupportRoot.appendingPathComponent("agent-runs", isDirectory: true)
    }

    /// Deletes everything in the temporary `recorded-audio` folder but this
    /// launch's renders: the playback copies 0.7.1 (75) kept there, and
    /// renders cut short by the app quitting. With no on-device model
    /// downloaded, also deletes Core ML's prepared copies of models deleted
    /// earlier. On the Mac, removes files left behind by the retired Chrome
    /// extension. Deletes the retired on-device writer (LFM3-Omni-2B, 1.1 GB,
    /// 0.7.15 and earlier). Runs at every launch, off the main thread; a
    /// missing folder or a failed delete is ignored. Downloaded on-device
    /// models (`Models`) are kept; Settings deletes them.
    public static func removeStaleFiles() {
        Task.detached(priority: .utility) {
            // Not in a test copy: the prepared-model cache is the real app's (Fable on #161).
            if FileLayout.testDataFolder == nil { LocalModelInstaller.removeUnusedPreparedModels() }
            try? FileManager.default.removeItem(at: FileLayout.appSupportRoot
                .appendingPathComponent("Models/lfm3-omni-2b", isDirectory: true))
            #if os(macOS)
            if FileLayout.overrideRoot == nil {
                FileLayout.removeRetiredChromeExtensionFiles()
            }
            #endif
            let fileManager = FileManager.default
            let renders = FileLayout.partialRendersFolder.deletingLastPathComponent()
            for old in (try? fileManager.contentsOfDirectory(at: renders, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent != FileLayout.partialRendersFolder.lastPathComponent {
                try? fileManager.removeItem(at: old)
            }
        }
    }

    #if os(macOS)
    /// Chromium browsers where earlier builds installed `io.blue.voiceiq.browser.json`.
    static let retiredBrowserFolders = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Google/Chrome for Testing",
        "Google/ChromeForTesting", "Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser",
        "Arc/User Data", "Vivaldi",
    ]
    static let retiredNativeHostManifestName = "io.blue.voiceiq.browser.json"

    /// Removes files earlier builds installed for the retired Chrome extension:
    /// the copied extension folder, its daily speaker log, and the native
    /// messaging host manifest in each Chromium browser's support folder.
    /// Idempotent and safe to run on every launch.
    @discardableResult
    static func removeRetiredChromeExtensionFiles(
        appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        voiceIQSupport: URL = FileLayout.appSupportRoot
    ) -> Int {
        let fileManager = FileManager.default
        var removed = 0
        for name in ["ChromeExtension", "ChromeExtension.new", "browser-speakers"] {
            if removeIfPresent(voiceIQSupport.appendingPathComponent(name, isDirectory: true), fileManager: fileManager) {
                removed += 1
            }
        }
        for browser in retiredBrowserFolders {
            let manifest = appSupport
                .appendingPathComponent(browser, isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                .appendingPathComponent(retiredNativeHostManifestName)
            if removeIfPresent(manifest, fileManager: fileManager) {
                removed += 1
            }
        }
        if removed > 0 {
            Log.session.info("removed \(removed, privacy: .public) retired Chrome extension item(s)")
        }
        return removed
    }

    private static func removeIfPresent(_ url: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            return false
        } catch {
            Log.session.error("failed to remove retired \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
    #endif

    /// Creates (if needed) and returns a fresh session folder. Name is
    /// timestamp-prefixed for human sortability in Finder.
    public static func makeSessionFolder(id: UUID, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(formatter.string(from: now))-\(id.uuidString.prefix(8))"
        let url = recordingsRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func audioCAF(in folder: URL) -> URL { folder.appendingPathComponent("audio.caf") }

    /// Duration estimate from CAF byte size (16kHz mono Int16 ≈ 32,000 B/s) — for
    /// crash-recovered sessions whose meta never got a duration (audit #7).
    public static func estimatedDuration(ofCAF url: URL) -> Double? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              bytes > 4096 else { return nil }
        return Double(bytes) / 32_000
    }
    public static func audioFLAC(in folder: URL) -> URL { folder.appendingPathComponent("audio.flac") }
    /// The `.m4a` that Play and Download make from a recording (`RecordedAudio`),
    /// kept beside the audio so deleting either removes it too.
    public static func playbackFolder(in folder: URL) -> URL { folder.appendingPathComponent("playback", isDirectory: true) }
    /// Where `RecordedAudio` renders before moving the file into
    /// `playbackFolder`: one folder per launch, so the launch cleanup never
    /// touches a render already running.
    public static let partialRendersFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("recorded-audio", isDirectory: true)
        .appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
    public static func metaJSON(in folder: URL) -> URL { folder.appendingPathComponent("meta.json") }
}
