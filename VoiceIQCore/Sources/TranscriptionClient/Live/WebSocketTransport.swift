import Foundation

/// The real socket.
///
/// The Gemini credential goes in the `x-goog-api-key` HEADER, never `?key=`. A
/// TLS-terminating proxy logs the request line, query string included, so
/// `?key=` would write the user's long-lived API key into whatever keeps those
/// logs. This matches `GeminiClient`'s rule for every other call the app makes.
///
/// `close()` is final. A transport closed before `connect()` refuses to
/// connect, so a session aborted mid-handshake can never open a socket after
/// the fact, and closing cancels the task, which fails any pending `send` or
/// `receive` at once.
public final class WebSocketTransport: LiveTransport, @unchecked Sendable {

    public static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// OpenAI's realtime transcription session. `intent=transcription` opens a
    /// transcription-only session (probed 2026-09-28).
    public static let openAIEndpoint = "wss://api.openai.com/v1/realtime?intent=transcription"

    private let makeRequest: @Sendable () -> URLRequest
    /// Text frames for APIs that read JSON only from text messages.
    private let sendsText: Bool
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private let lock = NSLock()

    /// Gemini's Live API.
    public convenience init(apiKey: @escaping @Sendable () -> String) {
        self.init(sendsText: false) {
            var request = URLRequest(url: URL(string: Self.endpoint)!)
            request.setValue(apiKey(), forHTTPHeaderField: "x-goog-api-key")
            return request
        }
    }

    /// OpenAI's realtime transcription session.
    public static func openAI(apiKey: @escaping @Sendable () -> String) -> WebSocketTransport {
        WebSocketTransport(sendsText: true) {
            var request = URLRequest(url: URL(string: openAIEndpoint)!)
            request.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    public init(sendsText: Bool, request: @escaping @Sendable () -> URLRequest) {
        self.makeRequest = request
        self.sendsText = sendsText
        let config = URLSessionConfiguration.ephemeral
        // Fail fast rather than parking. `waitsForConnectivity` would leave an
        // offline dictation holding an unresolved connection while the ring
        // fills and drops — the batch fallback can only run once this admits
        // defeat. Matches GeminiClient.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func connect() async throws {
        let task: URLSessionWebSocketTask? = lock.withLock {
            guard !closed, self.task == nil else { return nil }
            let task = session.webSocketTask(with: makeRequest())
            self.task = task
            return task
        }
        guard let task else { throw LiveError.aborted }
        task.resume()
    }

    public func send(_ data: Data) async throws {
        let task = try currentTask()
        do {
            if sendsText, let text = String(data: data, encoding: .utf8) {
                try await task.send(.string(text))
            } else {
                try await task.send(.data(data))
            }
        } catch {
            throw describe(error, task: task)
        }
    }

    public func receive() async throws -> Data {
        let task = try currentTask()
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw describe(error, task: task)
        }
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            return Data()
        }
    }

    public func close() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            let task = self.task
            self.task = nil
            closed = true
            return task
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func currentTask() throws -> URLSessionWebSocketTask {
        guard let task = lock.withLock({ self.task }) else { throw LiveError.aborted }
        return task
    }

    /// The refusal the server gave, when there was one: an HTTP status on the
    /// upgrade (401, 429) or a close code and reason (Gemini closes with 1011
    /// and a quota message). These are what tell quota apart from a dropped
    /// network.
    private func describe(_ error: Error, task: URLSessionWebSocketTask) -> Error {
        if lock.withLock({ closed }) { return LiveError.aborted }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            return LiveFailure(status: http.statusCode, message: "WebSocket upgrade refused",
                               retryAfter: LiveFailure.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
        }
        if task.closeCode != .invalid {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return LiveFailure(code: "websocket_\(task.closeCode.rawValue)", message: reason)
        }
        return error
    }
}
