#if os(iOS)
import Foundation
import os
import VoiceIQBridge

/// The iPhone keyboard's background `URLSession`, which sends a dictation's
/// transcription request when the keyboard can't wait for it: it was hidden
/// and its time ran out, or the device is offline (the session waits for the
/// network). iOS runs the transfer outside the keyboard and, when the
/// keyboard is gone, launches VoiceiQ in the background with
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`;
/// the app connects to the same identifier and gets the answer.
///
/// Bodies and answers are files in the App Group (`KeyboardJob`), so either
/// process can finish the job with `finish(_:service:)`.
public final class KeyboardTransfers: NSObject, URLSessionDataDelegate, Sendable {
    public static let identifier = "io.blue.voiceiq.keyboard.transcribe"
    /// The session waits for a network; only the provider's silence counts.
    static let requestTimeout: TimeInterval = 120

    private let root: URL?
    private let onAnswer: @Sendable (UUID) -> Void
    private let eventsDone = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// `onAnswer` runs on the session's queue once a job's answer is on disk.
    public init(root: URL? = KeyboardInbox.root, onAnswer: @escaping @Sendable (UUID) -> Void) {
        self.root = root
        self.onAnswer = onAnswer
    }

    /// Connects to the background session. One process at a time: the
    /// keyboard when it hands a job over, the app when iOS wakes it for one.
    public func connect() -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sharedContainerIdentifier = SharedStore.appGroupID
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Background sessions apply this, not the request's own timeout
        // (the Simulator dropped a 66 s answer at the 60 s default).
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// App: iOS's completion handler, called once the session's events are in.
    public func setEventsDone(_ handler: @escaping @Sendable () -> Void) {
        eventsDone.withLock { $0 = handler }
    }

    /// The jobs whose transfer is still running on `session`: the app
    /// leaves them to their answer instead of sending them again.
    public static func activeJobIDs(on session: URLSession) async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    /// Sends `request` for `job`, with its body from a file as background
    /// sessions require. The job is on disk before the transfer starts.
    @discardableResult
    public static func send(_ request: URLRequest, for job: KeyboardJob, on session: URLSession,
                            root: URL? = KeyboardInbox.root) throws -> URLSessionUploadTask {
        guard let bodyURL = KeyboardJob.bodyURL(job.id, root: root) else { throw CocoaError(.fileNoSuchFile) }
        // The body first: a job is published only once it can be sent.
        try FileManager.default.createDirectory(at: bodyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (request.httpBody ?? Data()).write(to: bodyURL, options: .atomic)
        do {
            try job.write(root: root)
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
        var request = request
        request.httpBody = nil
        request.timeoutInterval = requestTimeout
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = job.id.uuidString
        task.resume()
        return task
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription.flatMap(UUID.init(uuidString:)),
              let url = KeyboardJob.responseURL(id, root: root) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        KeyboardJob.record(KeyboardJob.Answer(status: status, error: error.map { "\($0)" }), for: id, root: root)
        onAnswer(id)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = eventsDone.withLock { handler in defer { handler = nil }; return handler }
        if let handler { DispatchQueue.main.async(execute: handler) }
    }

    // MARK: - Finishing a job

    /// What became of a job's dictation.
    public enum Outcome: Sendable, Equatable {
        /// The text, also written to the session's meta.json.
        case finished(TranscriptionResult)
        /// No answer yet, or the answer says try again later: the job stays.
        case waiting
        /// The provider refused it, or the step after its answer failed;
        /// the session is marked failed for History, with Retry.
        case failed(String)
        /// Another call, in this process or the other one, is finishing
        /// this job already.
        case busy
    }

    /// Jobs being finished in this process: iOS's events, the app's launch
    /// import and the session's wake-up can each ask for the same job.
    @MainActor private static var finishing: Set<UUID> = []

    /// Runs the rest of the pipeline on a job's answer, as the coordinator
    /// would have: the service parses the provider's answer (replayed, not
    /// sent again), then the writing model, Translate or Ask run as usual.
    /// The session's meta.json gets the words; the caller moves the folder
    /// and holds the text.
    @MainActor
    public static func finish(_ job: KeyboardJob, service: GeminiTranscriptionService,
                              root: URL? = KeyboardInbox.root) async -> Outcome {
        guard let answer = job.answer(root: root), let folder = job.folderURL(root: root) else { return .waiting }
        guard finishing.insert(job.id).inserted else { return .busy }
        defer { finishing.remove(job.id) }
        // The other process (keyboard or app) may be finishing it already.
        guard job.claim(root: root) else { return .busy }
        defer { job.releaseClaim(root: root) }
        guard let status = answer.status else {
            Log.transcription.notice("keyboard job \(job.id, privacy: .public): transfer ended without an answer (\(answer.error ?? "", privacy: .private))")
            return .waiting
        }
        let body = KeyboardJob.responseURL(job.id, root: root).flatMap { try? Data(contentsOf: $0) } ?? Data()
        var meta = SessionMeta.read(from: folder) ?? SessionMeta(id: job.id, startedAt: job.createdAt, status: .transcribing)
        let replay = ReplayedResponse(body: body, status: status)
        do {
            let scope = UsageScope(mode: job.context.mode, sessionID: meta.id.uuidString)
            let result = try await GeminiClient.$replayedTranscription.withValue(replay) {
                try await UsageMeter.$scope.withValue(scope) {
                    try await service.transcribe(audioURL: FileLayout.audioCAF(in: folder),
                                                 durationSeconds: job.durationSeconds, context: job.context)
                }
            }
            meta.rawTranscript = result.rawTranscript
            meta.cleanedTranscript = result.cleanedTranscript
            meta.modelID = result.modelID
            meta.status = .recovered
            meta.errorCode = nil
            meta.write(to: folder)
            RetentionPolicy.dropAudioIfNeverKept(meta, folder: folder)
            return .finished(result)
        } catch let error as TranscriptionError where error.isWorthRetrying && !replay.transcribed {
            Log.transcription.notice("keyboard job \(job.id, privacy: .public): \(String(describing: error), privacy: .public); left for the app's retry")
            meta.status = .queuedForRetry
            meta.errorCode = "keyboard_transfer"
            meta.write(to: folder)
            return .waiting
        } catch {
            meta.status = .failed
            meta.errorCode = "keyboard_transfer"
            meta.errorMessage = "\(error)"
            meta.write(to: folder)
            return .failed("\(error)")
        }
    }
}

extension TranscriptionError {
    /// Errors the app's retry queue sends again later.
    var isWorthRetrying: Bool {
        switch self {
        case .offline, .network, .timeout, .rateLimitedTransient, .rateLimitedDaily: return true
        default: return false
        }
    }
}
#endif
