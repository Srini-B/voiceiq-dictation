import Foundation

/// The transport under `GeminiClient.post`: one URLSession per request,
/// client request IDs, per-attempt metrics, and the one retry a lost
/// connection gets.
///
/// WHY a session per request (2026-10-02 investigation):
/// - With one long-lived session, CFNetwork learned HTTP/3 from each host's
///   `Alt-Svc` header and reused idle QUIC connections. Two failure shapes
///   followed: an ElevenLabs request on a connection idle for 72 s got a QUIC
///   stateless reset and failed in 42 ms with -1005 (shown as "offline"), and
///   an earlier OpenAI cleanup reused a connection idle for 134 s.
/// - There is no public API to turn HTTP/3 off for a session or request
///   (Apple DTS: "There's not a good way to disable QUIC for a specific
///   URLSession"; `assumesHTTP3Capable` only opts in). URLSession learns
///   HTTP/3 from DNS HTTPS records or `Alt-Svc`. None of our hosts publishes
///   an HTTPS record advertising h3 (api.openai.com, api.elevenlabs.io,
///   generativelanguage.googleapis.com have none; openrouter.ai advertises
///   h2 only; ai-gateway.vercel.sh is a CNAME), and an ephemeral session's
///   `Alt-Svc` memory is its own.
/// - So a new ephemeral session per request always starts on TCP + HTTP/2
///   (probed from the MacBook on all five hosts) and never reuses an idle
///   connection. Each call pays one TCP + TLS handshake, measured at 30–150 ms
///   against calls of 1–5 s.
extension GeminiClient {
    static func makeSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false // fail fast into the retry/queue path
        // Recordings are no longer capped at 10 minutes; a one-hour upload on a
        // slow uplink needs more than the old 600s resource budget.
        config.timeoutIntervalForResource = 3_600
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    static let requestIDHeader = "X-Client-Request-Id"

    /// The response of one call. A connection lost before any response
    /// (`-1005`: a reset, a dead pooled connection, a Wi-Fi blip) gets one
    /// immediate attempt on a new session with whatever deadline is left.
    ///
    /// Non-idempotent POSTs: the lost attempt may still have reached the
    /// provider, so a retry can be billed twice. It cannot be shown twice:
    /// this returns exactly one response, and only the caller decides what to
    /// insert. Nothing else is retried here: a timeout already spent the
    /// deadline (callers retry it), and an HTTP status is an answer.
    static func perform(
        _ request: URLRequest, deadline: TimeInterval, stage: UsageStage, via: ModelEndpoint, modelLabel: String
    ) async throws -> (Data, URLResponse) {
        var request = request
        let requestID = UUID().uuidString
        request.setValue(requestID, forHTTPHeaderField: requestIDHeader)
        let started = Date()
        var attempt = 1
        while true {
            let remaining = deadline - Date().timeIntervalSince(started)
            request.timeoutInterval = remaining
            let collector = TransportMetricsCollector()
            let session = makeSession(delegate: collector)
            let attemptStart = Date()
            do {
                defer { session.finishTasksAndInvalidate() }
                // URLRequest.timeoutInterval is an IDLE timer; enforce the true
                // overall deadline ourselves (audit L5).
                let result = try await withDeadline(seconds: remaining) { [session, request] in
                    try await session.data(for: request)
                }
                let status = (result.1 as? HTTPURLResponse)?.statusCode
                record(collector, requestID: requestID, attempt: attempt, stage: stage, via: via, model: modelLabel,
                       request: request, started: attemptStart, status: status,
                       outcome: status.map { (200...299).contains($0) } == true ? "ok" : "http_\(status ?? -1)")
                return result
            } catch {
                let outcome = outcomeName(error)
                record(collector, requestID: requestID, attempt: attempt, stage: stage, via: via, model: modelLabel,
                       request: request, started: attemptStart, status: nil, outcome: outcome)
                let left = deadline - Date().timeIntervalSince(started)
                if attempt == 1, (error as? URLError)?.code == .networkConnectionLost, left > 1 {
                    Log.transcription.notice("\(stage.rawValue, privacy: .public) request \(requestID, privacy: .public): connection lost after \(Int(Date().timeIntervalSince(attemptStart) * 1000))ms, retrying once on a new connection")
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    static func outcomeName(_ error: Error) -> String {
        if error is DeadlineExceeded { return "timeout" }
        guard let urlError = error as? URLError else { return "error" }
        switch urlError.code {
        case .networkConnectionLost: return "connection_lost"
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return "offline"
        default: return "url_\(urlError.code.rawValue)"
        }
    }

    private static func record(
        _ collector: TransportMetricsCollector, requestID: String, attempt: Int, stage: UsageStage,
        via: ModelEndpoint, model: String, request: URLRequest, started: Date, status: Int?, outcome: String
    ) {
        let metrics = collector.transaction
        func ms(_ from: Date?, _ to: Date?) -> Int? {
            guard let from, let to else { return nil }
            return Int(to.timeIntervalSince(from) * 1000)
        }
        let event = TransportEvent(
            at: started, requestID: requestID, attempt: attempt, stage: stage.rawValue, via: via.rawValue,
            model: model, host: request.url?.host, networkProtocol: metrics?.networkProtocolName,
            reusedConnection: metrics?.isReusedConnection,
            connectMs: ms(metrics?.connectStartDate, metrics?.connectEndDate),
            firstByteMs: ms(metrics?.requestStartDate, metrics?.responseStartDate),
            totalMs: Int(Date().timeIntervalSince(started) * 1000),
            requestBytes: metrics?.countOfRequestBodyBytesSent, responseBytes: metrics?.countOfResponseBodyBytesReceived,
            status: status, outcome: outcome
        )
        TransportLog.record(event)
        Log.transcription.notice("call \(event.stage, privacy: .public) via \(event.via, privacy: .public) (\(model, privacy: .public)) id=\(requestID, privacy: .public) attempt=\(attempt) \(event.networkProtocol ?? "-", privacy: .public)\(event.reusedConnection == true ? " reused" : "", privacy: .public) \(outcome, privacy: .public) in \(event.totalMs)ms, first byte \(event.firstByteMs ?? -1)ms, sent \(event.requestBytes ?? 0) bytes")
    }

    /// When the second attempt starts and how long it may run. Cleanup normally
    /// answers in 2.5–5.7 s (gpt-6-luna, measured from History 2026-10-01/02),
    /// so silence for 45% of the budget is treated as a stall. The second
    /// attempt gets what is left, never less than 8 s, so the worst case stays
    /// close to the single-attempt deadline.
    static func freshRetryTiming(deadline: TimeInterval) -> (startAfter: TimeInterval, deadline: TimeInterval) {
        let startAfter = min(max(deadline * 0.45, 5), 20)
        return (startAfter, max(8, deadline - startAfter))
    }

    /// Errors a new connection can fix. Anything about the key, the model, the
    /// request or a quota fails the same way on any connection.
    static func isConnectionFailure(_ error: Error) -> Bool {
        switch error as? TranscriptionError {
        case .timeout, .network, .offline: return true
        default: return false
        }
    }

    /// `cleanup`, plus a second attempt (its own connection, like every call) when the first has
    /// not answered by `startAfter` or fails with a connection error first.
    /// The first success wins and cancels the other attempt.
    nonisolated func cleanupWithFreshRetry(
        prompt: String, images: [Data], model: String, endpoint: URL, deadline: TimeInterval
    ) async throws -> String {
        let timing = Self.freshRetryTiming(deadline: deadline)
        return try await Self.firstSuccess(
            retryAfter: timing.startAfter,
            first: { try await self.cleanup(prompt: prompt, images: images, model: model,
                                            endpoint: endpoint, deadline: deadline) },
            retry: {
                try await self.cleanup(prompt: prompt, images: images, model: model,
                                       endpoint: endpoint, deadline: timing.deadline)
            }
        )
    }

    private enum Attempt: Sendable {
        case first(Result<String, Error>)
        case retry(Result<String, Error>)
        case retryDue
    }

    /// Runs `first`; starts `retry` once `retryAfter` passes without an answer,
    /// or as soon as `first` fails with a connection error. Returns the first
    /// success. When every started attempt fails, throws the last error.
    static func firstSuccess(
        retryAfter: TimeInterval,
        first: @escaping @Sendable () async throws -> String,
        retry: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: Attempt.self) { group in
            group.addTask { .first(await outcome(first)) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                return .retryDue
            }
            var retryStarted = false
            var inFlight = 1
            while let attempt = try await group.next() {
                var startReason: String?
                switch attempt {
                case .retryDue:
                    startReason = "no answer after \(String(format: "%.1f", retryAfter))s"
                case .first(.success(let text)):
                    group.cancelAll()
                    return text
                case .retry(.success(let text)):
                    Log.transcription.notice("cleanup: the second attempt answered")
                    group.cancelAll()
                    return text
                case .first(.failure(let error)):
                    inFlight -= 1
                    if isConnectionFailure(error) {
                        startReason = "first attempt failed (\(String(describing: error)))"
                    } else if inFlight == 0 {
                        group.cancelAll()
                        throw error
                    }
                case .retry(.failure(let error)):
                    inFlight -= 1
                    if inFlight == 0 { group.cancelAll(); throw error }
                }
                if let startReason, !retryStarted {
                    retryStarted = true
                    inFlight += 1
                    Log.transcription.notice("cleanup: \(startReason, privacy: .public), starting a second attempt")
                    group.addTask { .retry(await outcome(retry)) }
                } else if case .first(.failure(let error)) = attempt, inFlight == 0 {
                    // A connection failure after the retry already failed.
                    group.cancelAll()
                    throw error
                }
            }
            throw TranscriptionError.timeout // unreachable: an attempt always settles
        }
    }

    private static func outcome(_ body: @Sendable () async throws -> String) async -> Result<String, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

/// Keeps the last transaction's metrics of the one request its session runs.
final class TransportMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var last: URLSessionTaskTransactionMetrics?

    var transaction: URLSessionTaskTransactionMetrics? {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); last = metrics.transactionMetrics.last; lock.unlock()
    }
}
