import Foundation

/// Where everything lives on disk. One folder per dictation, Superwhisper-proven
/// layout: audio.caf (crash-safe master), audio.flac (upload copy, M3+), meta.json.
public enum FileLayout {
    /// Test hook: unit tests MUST sandbox here — the suite once wrote failed-
    /// session folders straight into the user's real History.
    public static var overrideRoot: URL?

    public static var appSupportRoot: URL {
        if let overrideRoot { return overrideRoot }
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

    public static var recordingsRoot: URL {
        appSupportRoot.appendingPathComponent("recordings", isDirectory: true)
    }

    public static var meetingsRoot: URL {
        appSupportRoot.appendingPathComponent("meetings", isDirectory: true)
    }

    public static var agentRunsRoot: URL {
        appSupportRoot.appendingPathComponent("agent-runs", isDirectory: true)
    }

    /// Deletes the on-device models that builds before 2026-11-10 downloaded
    /// (the whole `Models` folder), and on the Mac the speech helper's Core ML
    /// cache. Runs at every launch, off the main thread; a missing folder or a
    /// failed delete is ignored.
    public static func removeRetiredModels() {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: FileLayout.appSupportRoot.appendingPathComponent("Models", isDirectory: true))
            #if os(macOS)
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? fileManager.removeItem(at: caches.appendingPathComponent("io.blue.voiceiq.localspeech", isDirectory: true))
            #endif
        }
    }

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
    public static func metaJSON(in folder: URL) -> URL { folder.appendingPathComponent("meta.json") }
    /// Transcripts of the chunks that already succeeded on a multi-request
    /// upload, so a retry after a mid-way failure re-sends only what is missing.
    public static func chunkTranscripts(in folder: URL) -> URL { folder.appendingPathComponent("chunks.json") }
}
