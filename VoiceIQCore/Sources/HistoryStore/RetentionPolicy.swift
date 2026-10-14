import Foundation

/// Audio retention (the setting Superwhisper lacks): purge audio files after N
/// days while KEEPING transcripts + meta (until the user deletes them, or
/// until the separate transcript retention removes the whole dictation).
/// Audio is never deleted before a transcript exists — that would break Retry.
public struct RetentionPolicy: Sendable {
    public var audioRetentionDays: Int
    public var transcriptRetentionDays: Int

    public init(audioRetentionDays: Int = SettingsStore().audioRetentionDays,
                transcriptRetentionDays: Int = SettingsStore().transcriptRetentionDays) {
        self.audioRetentionDays = audioRetentionDays
        self.transcriptRetentionDays = transcriptRetentionDays
    }

    /// Both purges, in the order that matters: whole dictations first, then
    /// the audio of those that stay.
    public func purge(now: Date = Date()) {
        purgeExpiredTranscripts(now: now)
        purgeExpiredAudio(now: now)
    }

    /// Statuses a dictation ends in. Anything else is in flight or waiting
    /// for the user (Retry, a secure field, the chip) and stays whatever
    /// its age.
    static let finishedStatuses: [SessionMeta.Status] = [
        .inserted, .copiedToClipboard, .recovered, .silent, .cancelled, .failed,
    ]

    public func purgeExpiredTranscripts(store: HistoryStore? = nil, now: Date = Date()) {
        guard transcriptRetentionDays != 0, let store = store ?? (try? HistoryStore.standard()) else { return }
        let cutoff = transcriptRetentionDays < 0
            ? now.addingTimeInterval(60)
            : now.addingTimeInterval(-Double(transcriptRetentionDays) * 86_400)
        let removed = store.deleteExpired(before: cutoff, statuses: Self.finishedStatuses.map(\.rawValue))
        if removed > 0 {
            Log.history.info("RetentionPolicy: removed \(removed) dictation(s) older than \(self.transcriptRetentionDays)d")
        }
    }

    public func purgeExpiredAudio(recordingsRoot: URL = FileLayout.recordingsRoot, now: Date = Date()) {
        // 0 = keep forever; -1 = "Never keep audio": purge immediately once a
        // transcript exists (audit #2 — this option previously did NOTHING).
        guard audioRetentionDays != 0 else { return }
        let cutoff = audioRetentionDays < 0
            ? now.addingTimeInterval(60) // everything eligible, incl. just-finished
            : now.addingTimeInterval(-Double(audioRetentionDays) * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: nil
        )) ?? []
        var purged = 0
        for folder in folders where folder.hasDirectoryPath {
            // Transcript-less cancelled rows are retention-IMMUNE: their audio is
            // the only artifact (the >=10s keep rule preserved it precisely so
            // Retry works), and History advertises "audio kept". Purging it made
            // that row a lie with a dead-end Retry (production pass 2).
            guard let meta = SessionMeta.read(from: folder),
                  meta.startedAt < cutoff,
                  meta.rawTranscript != nil || meta.status == .silent
            else { continue }
            for audio in [FileLayout.audioCAF(in: folder), FileLayout.audioFLAC(in: folder)] {
                if FileManager.default.fileExists(atPath: audio.path) {
                    try? FileManager.default.removeItem(at: audio)
                    purged += 1
                }
            }
        }
        if purged > 0 {
            Log.history.info("RetentionPolicy: purged \(purged) audio file(s) older than \(self.audioRetentionDays)d")
        }
    }
}
