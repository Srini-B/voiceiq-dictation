import Foundation
import Network

/// The offline queue (F1, critic reconciliation #5): drains on network-restored
/// and on launch; one session at a time; drained results NOTIFY and land in
/// History — never auto-insert (focus is long gone). Simple policy: no exponential
/// ladders; the network path monitor IS the retry signal.
@MainActor
public final class RetryQueue {
    private let store: HistoryStore
    private let transcription: TranscriptionServicing
    private let monitor = NWPathMonitor()
    /// A drain or a manual retry is sending a recording.
    public private(set) var draining = false
    private var lastPathSatisfied = false
    private var scheduledDrain: Task<Void, Never>?

    /// The text of each dictation a drain recovered, oldest first.
    public var onDrained: (([String]) -> Void)?
    /// Fired once per blocked drain: the queue hit an account-level wall
    /// (auth/daily quota) — rows KEEP their queued promise and retry on the
    /// next external signal (launch, network flap, key change).
    public var onDrainBlocked: ((TranscriptionError) -> Void)?

    public init(store: HistoryStore, transcription: TranscriptionServicing) {
        self.store = store
        self.transcription = transcription
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                let cameOnline = satisfied && !self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                if cameOnline {
                    Log.history.info("RetryQueue: network restored — draining")
                    await self.drain()
                }
            }
        }
        monitor.start(queue: .main)
        Task { await drain() } // launch drain
    }

    /// A per-minute throttle clears by itself, so the network path monitor is
    /// no signal for it. This is the one timed retry the queue has.
    public func scheduleDrain(after seconds: TimeInterval) {
        scheduledDrain?.cancel()
        scheduledDrain = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            Log.history.info("RetryQueue: rate-limit wait over — draining")
            await self?.drain()
        }
    }

    public func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        let retryable = store.retryableRecords()
        guard !retryable.isEmpty else { return }
        var recovered: [String] = []

        for record in retryable {
            switch await process(record) {
            case .recovered(let text):
                recovered.append(text)
            case .stillOffline:
                Log.history.info("RetryQueue: still offline — pausing drain")
                if !recovered.isEmpty { onDrained?(recovered) }
                return
            case .rateLimited(let wait):
                Log.history.info("RetryQueue: rate limited — draining again in \(Int(wait))s")
                if !recovered.isEmpty { onDrained?(recovered) }
                scheduleDrain(after: wait)
                return
            case .blocked(let error):
                // Auth/daily-quota walls apply to every remaining row: stop, keep
                // their queued status, tell the user ONCE — never silently convert
                // "will retry automatically" into permanent failures.
                Log.history.warning("RetryQueue: drain blocked (\(String(describing: error))) — keeping queue intact")
                if !recovered.isEmpty { onDrained?(recovered) }
                onDrainBlocked?(error)
                return
            case .failed, .skipped:
                continue
            }
        }
        if !recovered.isEmpty {
            onDrained?(recovered)
        }
    }

    /// Manual per-item retry (History context menu) — works on any record.
    /// Shares the draining guard so a manual retry can't double-process a record
    /// the drain is already sending (audit L20).
    /// History's Retry: transcribes the recording again, including one that
    /// already succeeded (the user retries because the text came out wrong).
    /// A finished dictation keeps its text and status unless the new attempt
    /// succeeds.
    public func retrySingle(_ record: DictationRecord) async -> RetryOutcome {
        guard !draining else { return .busy }
        draining = true
        defer { draining = false }
        switch await process(record, again: true) {
        case .recovered(let text):
            return .recovered(text: text)
        case .stillOffline:
            return .stillOffline
        case .rateLimited(let wait):
            scheduleDrain(after: wait)
            return .rateLimited(retryIn: wait)
        case .blocked(let error):
            onDrainBlocked?(error)
            return .blocked
        case .failed:
            return .failed
        case .skipped:
            return .alreadyDone
        }
    }

    /// User-facing outcome of a manual Retry — a silent no-op reads as broken.
    public enum RetryOutcome {
        case stillOffline, blocked, failed, alreadyDone, busy
        /// The new text, also written to the History row.
        case recovered(text: String)
        /// The throttle named its wait; a drain is already scheduled for it.
        case rateLimited(retryIn: TimeInterval)
    }

    /// Delivered one way or another; the drain leaves these alone.
    private static let finishedStatuses: Set<SessionMeta.Status> = [
        .inserted, .copiedToClipboard, .awaitingChip, .heldSecure, .recovered,
    ]

    private enum ProcessResult {
        case recovered(String), stillOffline, blocked(TranscriptionError), failed, skipped
        case rateLimited(TimeInterval)
    }

    /// The server's Retry-After plus slack, or a full minute when it gave none.
    private static func rateLimitWait(_ retryAfter: TimeInterval?) -> TimeInterval {
        (retryAfter ?? 60) + 2
    }

    /// `again`: a manual Retry, which transcribes even a finished dictation.
    /// The drain passes false and only picks up unfinished ones.
    private func process(_ record: DictationRecord, again: Bool = false) async -> ProcessResult {
        let folder = record.folderURL
        guard var meta = SessionMeta.read(from: folder) else { return .skipped }
        let finished = Self.finishedStatuses.contains(meta.status)
        // Re-read status from disk: a concurrent path may have finished it already.
        if finished, !again {
            return .skipped
        }
        // Transcript already exists (crash after transcription, audio since
        // purged): recover the WORDS instead of dead-ending on missing audio.
        let cafURL = FileLayout.audioCAF(in: folder)
        if finished, !FileManager.default.fileExists(atPath: cafURL.path) {
            return .failed // audio purged: nothing to transcribe again; keep the text
        }
        if meta.rawTranscript != nil, !finished {
            meta.status = .recovered
            meta.errorCode = nil
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .recovered(meta.cleanedTranscript ?? meta.rawTranscript ?? "")
        }
        guard FileManager.default.fileExists(atPath: cafURL.path) else {
            meta.status = .failed
            meta.errorCode = "audio_purged"
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .failed
        }
        do {
            let context = DictationContext(
                targetAppBundleID: meta.targetAppBundleID,
                targetAppName: meta.targetAppName
            )
            let scope = UsageScope(activity: .dictation, sessionID: meta.id.uuidString)
            let result = try await UsageMeter.$scope.withValue(scope) {
                try await transcription.transcribe(
                    audioURL: cafURL,
                    durationSeconds: meta.audioDurationSeconds
                        ?? FileLayout.estimatedDuration(ofCAF: cafURL)
                        ?? 60,
                    context: context
                )
            }
            meta.rawTranscript = result.rawTranscript
            meta.cleanedTranscript = result.cleanedTranscript
            meta.modelID = result.modelID
            meta.errorCode = nil
            meta.errorMessage = result.cleanupNote
            // .recovered, NOT .awaitingChip: the text was never put on the
            // clipboard, so no chip may promise "Ready to paste". A finished
            // dictation keeps its status: it was delivered, just differently.
            if !finished { meta.status = .recovered }
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .recovered(result.cleanedTranscript)
        } catch let error as TranscriptionError {
            // A finished dictation keeps its text; only report the failure.
            if finished {
                switch error {
                case .offline, .network, .timeout: return .stillOffline
                case .rateLimitedTransient(let retryAfter): return .rateLimited(Self.rateLimitWait(retryAfter))
                case .auth, .rateLimitedDaily: return .blocked(error)
                default: return .failed
                }
            }
            switch error {
            case .offline, .network, .timeout:
                return .stillOffline
            case .rateLimitedTransient(let retryAfter):
                return .rateLimited(Self.rateLimitWait(retryAfter))
            case .auth, .rateLimitedDaily:
                // Account-level wall: NOT this row's fault. Keep its queued
                // status untouched so the promise survives to the next drain.
                return .blocked(error)
            case .modelUnavailable(let model, let detail):
                meta.status = .failed
                meta.errorCode = "model"
                meta.errorMessage = detail ?? "model \(model) not accessible"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                return .failed
            case .badRequest(let message):
                // Permanent (audit #3): mark failed so the queue never spins on it.
                meta.status = .failed
                meta.errorCode = "bad_request"
                meta.errorMessage = message
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                Log.history.warning("RetryQueue: permanent failure for \(meta.id, privacy: .public): \(message, privacy: .private)")
                return .failed
            default:
                meta.status = .failed
                meta.errorCode = "retry_\(String(describing: error))"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                return .failed
            }
        } catch {
            // Non-TranscriptionError (e.g. FLAC encode on a corrupt CAF): mark it
            // failed so the queue never spins on it (audit L3).
            Log.history.error("RetryQueue: unexpected error \(error)")
            if finished { return .failed }
            meta.status = .failed
            meta.errorCode = "retry_unexpected"
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .failed
        }
    }
}
