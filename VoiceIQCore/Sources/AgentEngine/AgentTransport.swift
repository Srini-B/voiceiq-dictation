import Foundation
import os

/// One request to the session's host, in the host's format. Each adapter
/// renders the same `AgentConversation` and the same `AgentTool` list and
/// reads back one `AgentReply`. Usage is metered here, once per call.
public struct AgentTransport: Sendable {
    public var endpoint: AgentEndpoint
    /// What the Cost pane books each call as.
    let stage: UsageStage
    private let session: URLSession
    /// Shared by every copy of the transport, so one loop keeps one cache key.
    let hostState: HostState
    /// Hosts answer a 1,500-token prompt with a screenshot in a few seconds;
    /// a reasoning model on a proxy can take a minute.
    static let deadline: TimeInterval = 120

    /// `cacheKey` names the OpenAI cache the calls share. Nil gives this
    /// transport a key of its own; a conversation that outlives the app,
    /// such as a meeting chat, passes a stable one.
    public init(endpoint: AgentEndpoint, stage: UsageStage = .agentStep, cacheKey: String? = nil,
                session: URLSession? = nil) {
        self.endpoint = endpoint
        self.stage = stage
        hostState = HostState(promptCacheKey: cacheKey ?? "voiceiq-agent-" + UUID().uuidString)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.deadline
            config.timeoutIntervalForResource = Self.deadline * 2
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ conversation: AgentConversation) async throws -> AgentReply {
        switch endpoint.format {
        case .openAIChat: return try await sendOpenAIChat(conversation)
        case .openAIResponses: return try await sendOpenAIResponses(conversation)
        case .anthropicMessages: return try await sendAnthropic(conversation)
        case .googleGenerativeAI: return try await sendGemini(conversation)
        }
    }

    // MARK: - Shared

    var cachePolicy: AgentCachePolicy { AgentCachePolicy(endpoint: endpoint) }

    /// `body(true)` carries the cache fields for the model's vendor;
    /// `body(false)` is the same request without them. A host that answers
    /// 400 naming a cache field gets the plain body, once now and on every
    /// later call of the session. Keys are sorted so the bytes, and the
    /// host's view of the prefix, are the same from call to call.
    func post(path: String, extraQuery: [String: String] = [:],
              body: (_ cacheFields: Bool) -> [String: Any]) async throws -> (data: Data, root: [String: Any]) {
        let withCache = !hostState.cacheFieldsRejected
        do {
            return try await postOnce(path: path, extraQuery: extraQuery, body: body(withCache))
        } catch AgentTransportError.http(400, let message) where withCache && AgentCachePolicy.rejectsCacheFields(message) {
            Log.agent.notice("host refused cache fields, retrying without: \(message ?? "", privacy: .public)")
            hostState.cacheFieldsRejected = true
            return try await postOnce(path: path, extraQuery: extraQuery, body: body(false))
        }
    }

    private func postOnce(path: String, extraQuery: [String: String], body: [String: Any]) async throws -> (data: Data, root: [String: Any]) {
        var request = endpoint.request(path: path, extraQuery: extraQuery)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Log.agent.error("agent call failed: \((error as NSError).localizedDescription, privacy: .public)")
            throw AgentTransportError.network((error as NSError).localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = AgentTransportError.message(in: data)
            Log.agent.error("agent call \(status, privacy: .public): \(message ?? "", privacy: .public)")
            throw AgentTransportError.http(status, message)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AgentTransportError.malformed("not a JSON object")
        }
        return (data, root)
    }

    func record(_ usage: TokenUsage?) {
        guard let usage else { return }
        UsageMeter.record(stage: stage, model: endpoint.modelID, usage: usage)
    }

    static func dataURL(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    static func argumentsString(_ arguments: [String: JSONValue]) -> String {
        let object = arguments.mapValues(\.anyValue)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func parseArguments(_ any: Any?) -> [String: JSONValue] {
        if let object = any as? [String: Any] {
            return object.compactMapValues(JSONValue.init(any:))
        }
        if let text = any as? String, let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object.compactMapValues(JSONValue.init(any:))
        }
        return [:]
    }

    /// The text parts of a message joined, for hosts whose tool results are
    /// strings; images are handed back separately.
    static func split(_ content: [AgentContent]) -> (text: String, images: [(Data, String)]) {
        var text: [String] = []
        var images: [(Data, String)] = []
        for part in content {
            switch part {
            case .text(let value): text.append(value)
            case .image(let data, let mimeType): images.append((data, mimeType))
            }
        }
        return (text.joined(separator: "\n"), images)
    }
}

public extension Log {
    static let agent = LogChannel("agent")
}

/// Session-wide facts shared by every copy of the transport.
final class HostState: @unchecked Sendable {
    /// One per session, so every call lands on the same OpenAI cache.
    let promptCacheKey: String
    private let lock = NSLock()
    private var rejected = false

    init(promptCacheKey: String) { self.promptCacheKey = promptCacheKey }

    /// Set once a host has answered 400 to a cache field; the session then
    /// sends plain bodies rather than failing every call.
    var cacheFieldsRejected: Bool {
        get { lock.withLock { rejected } }
        set { lock.withLock { rejected = newValue } }
    }
}
