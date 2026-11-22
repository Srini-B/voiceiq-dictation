import Foundation

/// Launch-time crash recovery (F14, critic reconciliation #8):
/// the MOST RECENT interrupted session is auto-transcribed (that's the one the
/// user actually lost mid-flow); older interrupted folders become manual
/// "Recovered — Retry" rows. Never auto-insert — the focus context is gone.
/// The app may also copy the recovered text, when the user turned that on.
@MainActor
public final class RecoveryScanner {
    private let store: HistoryStore
    private let transcription: TranscriptionServicing
    private let recordingsRoot: URL

    /// The text of the dictation the launch scan recovered.
    public var onRecovered: ((String) -> Void)?

    public init(store: HistoryStore, transcription: TranscriptionServicing, recordingsRoot: URL = FileLayout.recordingsRoot) {
        self.store = store
        self.transcription = transcription
        self.recordingsRoot = recordingsRoot
    }

    /// `sparing` is the session the app is recording or transcribing now,
    /// read once the reindex is done: it is unfinished, not interrupted.
    public func scanAndRecover(sparing active: @MainActor () -> URL? = { nil }) async {
        // The reindex walks every recording folder and decodes every meta.json —
        // unbounded as history grows, and the hotkey is already armed by now, so
        // a key press would queue behind it on the main actor.
        let store = self.store
        let root = recordingsRoot
        await Task.detached(priority: .utility) { store.reindex(recordingsRoot: root) }.value
        let live = active()?.standardizedFileURL
        let interrupted = store.interruptedRecords().filter { $0.folderURL.standardizedFileURL != live }
        guard !interrupted.isEmpty else { return }
        Log.history.info("RecoveryScanner: \(interrupted.count) interrupted session(s) found")

        for (index, record) in interrupted.enumerated() {
            let folder = record.folderURL
            guard var meta = SessionMeta.read(from: folder) else { continue }

            // Crashed AFTER the transcript was stored (mid-insertion): the text
            // exists — surface it without re-uploading anything (audit L18).
            // MUST come before the audio check: under "Never keep audio" the CAF
            // is already purged, and the old order buried the recovered WORDS
            // as a dead-end "no_audio_file" failure (production pass 2, P0).
            if meta.rawTranscript != nil {
                meta.status = .recovered
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                if index == 0 {
                    onRecovered?(meta.cleanedTranscript ?? meta.rawTranscript ?? "")
                }
                continue
            }

            let cafURL = FileLayout.audioCAF(in: folder)
            guard FileManager.default.fileExists(atPath: cafURL.path) else {
                meta.status = .failed
                meta.errorCode = "no_audio_file"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                continue
            }

            if index == 0 {
                // Auto-transcribe only the most recent (quota-respectful).
                do {
                    // Crashed sessions never wrote a duration — estimate from the
                    // CAF so the network deadline scales properly (audit #7).
                    let duration = meta.audioDurationSeconds
                        ?? FileLayout.estimatedDuration(ofCAF: cafURL)
                        ?? 60
                    let context = DictationContext(
                        targetAppBundleID: meta.targetAppBundleID,
                        targetAppName: meta.targetAppName
                    )
                    let result = try await transcription.transcribe(
                        audioURL: cafURL, durationSeconds: duration, context: context
                    )
                    meta.rawTranscript = result.rawTranscript
                    meta.cleanedTranscript = result.cleanedTranscript
                    meta.modelID = result.modelID
                    meta.errorMessage = nil
                    meta.status = .recovered // text ready in History; the app copies it only when the user turned that on
                    meta.write(to: folder)
                    store.upsert(meta: meta, folder: folder)
                    onRecovered?(result.cleanedTranscript)
                    Log.history.info("RecoveryScanner: recovered \(record.id, privacy: .public)")
                } catch {
                    meta.status = .queuedForRetry
                    meta.write(to: folder)
                    store.upsert(meta: meta, folder: folder)
                    Log.history.warning("RecoveryScanner: recovery transcription failed — queued (\(error))")
                }
            } else {
                // Older interruptions: keep audio, mark for manual retry.
                meta.status = .queuedForRetry
                meta.errorCode = meta.errorCode ?? "recovered"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
            }
        }
    }
}
