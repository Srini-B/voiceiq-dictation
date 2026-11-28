import Foundation

/// A dictation streamed to AssemblyAI-STT-3.7-Realtime while it is recorded,
/// so its transcript is ready a fraction of a second after key-up.
///
/// Streaming is billed for the time the WebSocket is open, so the session
/// opens when recording starts and closes at key-up (`finish`) or on cancel,
/// never later. The audio is the same 16 kHz mono PCM the recording writes,
/// sent in chunks of 50 ms to 1 s (the API takes 20–1000 ms, no faster than
/// real time, which a live microphone never is).
///
/// At key-up `finish` sends ForceEndpoint, which ends the open turn at once
/// (its final arrives in about 120 ms, measured 2026-11-28), and Terminate,
/// then waits for the Termination message, by which every turn is final.
/// Anything that goes wrong (no connection, the server closing the stream,
/// no Termination in time) makes `finish` throw, and the caller transcribes
/// the recording from disk instead, so a failed stream never loses words.
public final class RealtimeTranscription: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let openedAt = Date()
    /// The dictation this stream belongs to; the socket's callbacks don't inherit it.
    private let scope = UsageMeter.scope
    private var pending: [Int16] = []
    private var finals: [Int: String] = [:]
    private var failure: TranscriptionError?
    private var terminated = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// Set once `finish` stops waiting, so a waiter that registers late resumes at once.
    private var waitOver = false
    private var closed = false

    /// 50 ms at 16 kHz: the smallest chunk sent while recording.
    static let chunkSamples = 800
    /// 1 s, the largest chunk the API accepts.
    static let maxChunkSamples = 16_000

    public init(apiKey: String, languageCode: String?) {
        var components = URLComponents(url: AssemblyAIConfig.streaming, resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "sample_rate", value: "16000"),
                     URLQueryItem(name: "speech_model", value: AssemblyAIConfig.realtimeModel),
                     // An abandoned session bills until the 3-hour cap; with
                     // no audio for this long the server closes it.
                     URLQueryItem(name: "inactivity_timeout", value: "30")]
        // No keyterms: they pull similar-sounding names toward the
        // Dictionary's (Karen became Karan), and the writer spells
        // Dictionary words anyway. MEASURED 2026-11-28 on the dictation eval:
        // names 77.9 with the Dictionary as keyterms, 95.7 without
        // (activities/2026-11-28-assemblyai.md).
        if let languageCode, let json = try? JSONSerialization.data(withJSONObject: [languageCode]) {
            query.append(URLQueryItem(name: "language_codes", value: String(decoding: json, as: UTF8.self)))
        }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.resume()
        receive()
        Log.transcription.notice("realtime: session opened")
    }

    deinit { close() }

    /// Samples as they are recorded. Called from the audio write queue.
    public func append(_ samples: [Int16]) {
        // Chunks leave outside the lock: a send's completion can take it.
        let chunks: [[Int16]] = lock.withLock {
            guard !closed, failure == nil else { return [] }
            pending.append(contentsOf: samples)
            var chunks: [[Int16]] = []
            while pending.count >= Self.chunkSamples {
                let count = min(pending.count, Self.maxChunkSamples)
                chunks.append(Array(pending.prefix(count)))
                pending.removeFirst(count)
            }
            return chunks
        }
        chunks.forEach(send)
    }

    /// Ends the stream at key-up and returns the transcript: every final turn
    /// in order. Throws when the stream failed or did not end in `timeout`.
    public func finish(timeout: TimeInterval = 4) async throws -> String {
        let (tail, failed) = lock.withLock {
            var tail = pending
            pending = []
            // Padded to a full chunk: the service refuses chunks under 20 ms
            // (some of its docs say 50).
            if !tail.isEmpty, tail.count < Self.chunkSamples {
                tail += Array(repeating: 0, count: Self.chunkSamples - tail.count)
            }
            return (tail, failure)
        }
        if let failed { close(); throw failed }
        if !tail.isEmpty { send(tail) }
        task.send(.string(#"{"type":"ForceEndpoint"}"#)) { _ in }
        task.send(.string(#"{"type":"Terminate"}"#)) { _ in }

        let ended: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if terminated || failure != nil || waitOver {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiter = continuation
                        lock.unlock()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first { resumeWaiter() }
            return first
        }
        close()
        let (failure, terminated, finals) = lock.withLock { (self.failure, self.terminated, self.finals) }
        if let failure { throw failure }
        guard ended, terminated else {
            Log.transcription.error("realtime: no Termination within \(timeout)s")
            throw TranscriptionError.timeout
        }
        return finals.keys.sorted().compactMap { finals[$0] }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
    }

    /// Drops the stream: a cancelled dictation, or one that went another way.
    public func cancel() { close() }

    private func send(_ samples: [Int16]) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        task.send(.data(data)) { [weak self] error in
            guard let error else { return }
            self?.fail(.network("realtime_send_\((error as NSError).code)"))
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(Self.mapClose(self.task, error: error))
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = Data()
                }
                if self.handle(data) { self.receive() }
            }
        }
    }

    /// Applies one server message; false once the stream is over.
    private func handle(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        switch json["type"] as? String {
        case "Turn":
            if json["end_of_turn"] as? Bool == true, let order = json["turn_order"] as? Int {
                lock.lock()
                finals[order] = json["transcript"] as? String ?? ""
                lock.unlock()
            }
            return true
        case "Termination":
            lock.lock()
            terminated = true
            lock.unlock()
            resumeWaiter()
            return false
        case "Error":
            // The service sends why before it closes, as {"error_code", "error"}.
            Log.transcription.error("realtime: \(String(decoding: data, as: UTF8.self), privacy: .private)")
            fail(Self.map(code: json["error_code"] as? Int ?? 0, reason: json["error"] as? String ?? "", error: nil))
            return false
        default:
            return true
        }
    }

    private func fail(_ error: TranscriptionError) {
        lock.lock()
        let first = failure == nil && !terminated
        if first { failure = error }
        lock.unlock()
        if first { Log.transcription.error("realtime: stream failed (\(String(describing: error), privacy: .public))") }
        resumeWaiter()
    }

    private func resumeWaiter() {
        lock.lock()
        let continuation = waiter
        waiter = nil
        waitOver = true
        lock.unlock()
        continuation?.resume()
    }

    private func close() {
        lock.lock()
        let wasOpen = !closed, ended = terminated
        closed = true
        lock.unlock()
        resumeWaiter()
        guard wasOpen else { return }
        // Terminate ends the session at once; the close frame alone may leave
        // it billing until the inactivity timeout. The socket closes once
        // Terminate is out, or after a second if the send never completes.
        let task = task
        if ended {
            task.cancel(with: .normalClosure, reason: nil)
        } else {
            task.send(.string(#"{"type":"Terminate"}"#)) { _ in task.cancel(with: .normalClosure, reason: nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { task.cancel(with: .normalClosure, reason: nil) }
        }
        session.finishTasksAndInvalidate()
        recordUsage()
    }

    /// Billed for the session's open time, in whole seconds, whether it was
    /// used or cancelled.
    private func recordUsage() {
        let seconds = Date().timeIntervalSince(openedAt).rounded(.up)
        UsageMeter.$scope.withValue(scope) {
            UsageMeter.record(stage: .liveTranscribe, model: AssemblyAIClient.label(AssemblyAIConfig.realtimeModel),
                              usage: TokenUsage(reportedCostUSD: seconds / 3600 * AssemblyAIPrices.realtimePerHour,
                                                audioSeconds: seconds))
        }
    }

    /// The server's close code and reason say why a stream ended (streaming
    /// docs, "Common session errors and closures"): 1008 is a rejected key,
    /// an account without funds, or too many new sessions this minute.
    static func mapClose(_ task: URLSessionWebSocketTask, error: Error) -> TranscriptionError {
        map(code: task.closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "",
            error: error)
    }

    /// A close code or an Error message's code, with its reason.
    static func map(code: Int, reason: String, error: Error?) -> TranscriptionError {
        let reason = reason.lowercased()
        switch code {
        case 1008 where reason.contains("insufficient funds"): return .noBalance
        case 1008 where reason.contains("too many"): return .rateLimitedTransient(retryAfter: nil)
        case 1008: return .auth
        case 0, 1000, 1001:
            if let urlError = error as? URLError, [.notConnectedToInternet, .dataNotAllowed].contains(urlError.code) {
                return .offline
            }
            return .network("realtime_closed")
        default: return .network("realtime_closed_\(code)")
        }
    }
}
