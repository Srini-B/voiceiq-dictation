import Foundation
import VoiceIQBridge

/// Dictations the iPhone keyboard recorded and processed itself, on their way
/// into the app's History.
///
/// The keyboard runs the same `DictationCoordinator` as the app with
/// `FileLayout.overrideRoot` set to `root`, so its session folders (audio,
/// meta.json with the step times) land in `root/recordings`. When a dictation
/// ends, the keyboard moves the folder to `root/finished` with its billed
/// calls in `usage.json`. The app moves finished folders, and folders the
/// keyboard abandoned (it was ended mid-dictation), into its own recordings
/// and adds them to History, where retry and recovery work as for its own.
/// The keyboard never opens the History or usage databases: a suspended
/// process holding a lock on a database in the shared container is ended by
/// iOS.
public enum KeyboardInbox {
    public static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)?
            .appendingPathComponent("KeyboardInbox", isDirectory: true)
    }

    private static let usageFile = "usage.json"
    /// A folder still in `recordings` this long after its last write was
    /// left behind by a keyboard that iOS ended.
    static let abandonedAfter: TimeInterval = 600

    /// Keyboard: the dictation in `folder` is over.
    public static func finish(folder: URL, usage: [UsageRecord], root: URL? = root) {
        guard let root, FileManager.default.fileExists(atPath: folder.path) else { return }
        let finished = root.appendingPathComponent("finished", isDirectory: true)
        try? FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        if !usage.isEmpty, let data = try? JSONEncoder().encode(usage) {
            try? data.write(to: folder.appendingPathComponent(usageFile))
        }
        try? FileManager.default.moveItem(at: folder, to: finished.appendingPathComponent(folder.lastPathComponent))
    }

    /// App: moves what the keyboard left into `FileLayout.recordingsRoot` and
    /// returns each folder's meta and new place, plus the billed calls.
    public static func collect(from root: URL? = root, now: Date = Date()) -> (sessions: [(meta: SessionMeta, folder: URL)], usage: [UsageRecord]) {
        guard let root else { return ([], []) }
        let fileManager = FileManager.default
        var candidates = (try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("finished"), includingPropertiesForKeys: nil)) ?? []
        for folder in (try? fileManager.contentsOfDirectory(at: root.appendingPathComponent("recordings"),
                                                           includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let touched = [FileLayout.metaJSON(in: folder), FileLayout.audioCAF(in: folder), folder]
                .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
                .max() ?? .distantPast
            if now.timeIntervalSince(touched) > abandonedAfter { candidates.append(folder) }
        }
        var sessions: [(SessionMeta, URL)] = []
        var usage: [UsageRecord] = []
        try? fileManager.createDirectory(at: FileLayout.recordingsRoot, withIntermediateDirectories: true)
        for folder in candidates {
            let usageURL = folder.appendingPathComponent(usageFile)
            if let data = try? Data(contentsOf: usageURL), let records = try? JSONDecoder().decode([UsageRecord].self, from: data) {
                usage += records
            }
            try? fileManager.removeItem(at: usageURL)
            let target = FileLayout.recordingsRoot.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            guard (try? fileManager.moveItem(at: folder, to: target)) != nil else { continue }
            if let meta = SessionMeta.read(from: target) { sessions.append((meta, target)) }
        }
        return (sessions, usage)
    }
}
