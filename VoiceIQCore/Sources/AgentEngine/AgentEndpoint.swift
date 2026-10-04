import Foundation

/// Where one agent session sends its calls. Resolved once at session
/// start, so a settings change mid-session cannot split the cached prefix
/// across two hosts.
public struct AgentEndpoint: Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var format: AgentAPIFormat
    public var headers: [String: String]
    public var queryParameters: [String: String]
    public var modelID: String
    /// For the transcript header and logs: "Custom" or the route's host.
    public var label: String
    public var isCustom: Bool

    public init(baseURL: URL, apiKey: String?, format: AgentAPIFormat, headers: [String: String] = [:],
                queryParameters: [String: String] = [:], modelID: String, label: String, isCustom: Bool) {
        self.baseURL = Self.stripAPIPath(baseURL)
        self.apiKey = apiKey
        self.format = format
        self.headers = headers
        self.queryParameters = queryParameters
        self.modelID = modelID
        self.label = label
        self.isCustom = isCustom
    }

    /// The custom override when it is complete and has a key; otherwise the
    /// dictation route's writing model over the same host dictation uses.
    public static func resolve(settings: SettingsStore = SettingsStore()) -> AgentEndpoint? {
        let override = settings.agentProviderOverride
        if override.isActive, let base = override.usableBaseURL, let model = override.selectedModel {
            return AgentEndpoint(
                baseURL: base,
                apiKey: KeychainStore.loadAgentProviderKey(),
                format: override.format,
                headers: Dictionary(AgentProviderOverride.pairs(override.headers).map { ($0.name, $0.value) }, uniquingKeysWith: { $1 }),
                queryParameters: Dictionary(AgentProviderOverride.pairs(override.queryParameters).map { ($0.name, $0.value) }, uniquingKeysWith: { $1 }),
                modelID: model.id,
                label: base.host ?? "Custom",
                isCustom: true
            )
        }
        let route = settings.activeRoute
        let gemini = settings.geminiConfig
        let openAI = settings.openAIConfig
        switch route.endpoint {
        case .gemini:
            guard let key = KeychainStore.loadAPIKey() else { return nil }
            return AgentEndpoint(baseURL: gemini.endpoint, apiKey: key, format: .googleGenerativeAI,
                                 modelID: gemini.cleanupModel, label: route.displayName, isCustom: false)
        case .openAI:
            guard let key = KeychainStore.loadOpenAIKey() else { return nil }
            return AgentEndpoint(baseURL: URL(string: "https://api.openai.com")!, apiKey: key, format: .openAIChat,
                                 modelID: openAI.writingModel, label: route.displayName, isCustom: false)
        case .openRouter, .vercel:
            let key = route.endpoint == .openRouter ? KeychainStore.loadOpenRouterKey() : KeychainStore.loadVercelKey()
            guard let key else { return nil }
            let base = route.endpoint == .openRouter ? "https://openrouter.ai/api" : "https://ai-gateway.vercel.sh"
            let model = route.provider == .gemini ? "google/\(gemini.cleanupModel)" : "openai/\(openAI.writingModel)"
            return AgentEndpoint(baseURL: URL(string: base)!, apiKey: key, format: .openAIChat,
                                 modelID: model, label: route.displayName, isCustom: false)
        case .elevenLabs, .sarvam:
            return nil
        }
    }

    /// Users paste `https://host/v1` from other tools' instructions. The
    /// transport appends the versioned path itself, so a trailing `/v1` or
    /// `/v1beta` would double up; drop it.
    static func stripAPIPath(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/v1beta", "/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        components?.path = path
        return components?.url ?? url
    }

    /// `base/path?query`, with the user's query parameters on every call.
    func url(path: String, extraQuery: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + "/" + path
        let query = queryParameters.merging(extraQuery) { $1 }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        }
        return components.url!
    }

    /// "VoiceiQ/0.5.9 (34)": identifies the app in host logs such as
    /// CLIProxyAPI's. A user header of the same name replaces it.
    static let userAgent: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "VoiceiQ/\(version) (\(build))"
    }()

    /// A request with auth and the user's headers applied. Auth is set
    /// first, so a user header of the same name wins.
    func request(path: String, method: String = "POST", extraQuery: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(path: path, extraQuery: extraQuery))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            switch format {
            case .googleGenerativeAI: request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            case .anthropicMessages:
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .openAIChat, .openAIResponses: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        if format == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Model ids the host lists, for Save & Validate. Empty on success
    /// means the host answered but named nothing.
    public func listModels(session: URLSession = .shared) async throws -> [String] {
        let request = request(path: format.modelsPath, method: "GET")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AgentTransportError.http(status, AgentTransportError.message(in: data)) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let list = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            if let id = item["id"] as? String { return id }
            if let name = item["name"] as? String { return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name }
            return nil
        }
    }
}

public enum AgentTransportError: Error, Equatable, Sendable {
    case noEndpoint
    case http(Int, String?)
    case malformed(String)
    case network(String)

    /// For the transcript.
    public var userMessage: String {
        switch self {
        case .noEndpoint: return "No model is set up. Add a provider key in Settings, or a custom provider under Experimental."
        case .http(401, _), .http(403, _): return "The model host refused the key."
        case .http(404, let detail): return "The model host has no such model or path\(detail.map { ": \($0)" } ?? "")."
        case .http(429, _): return "The model host is rate limiting; try again in a moment."
        case .http(let status, let detail): return "The model host answered \(status)\(detail.map { ": \($0)" } ?? "")."
        case .malformed(let detail): return "Couldn't read the model's reply (\(detail))."
        case .network(let detail): return "Couldn't reach the model host (\(detail))."
        }
    }

    static func message(in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let text = String(data: data.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        if let error = root["error"] as? [String: Any] { return error["message"] as? String }
        return root["message"] as? String ?? root["error"] as? String
    }
}
