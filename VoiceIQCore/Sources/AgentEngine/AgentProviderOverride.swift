import Foundation

/// The request and response shape of a model host. An enum, so the
/// transport never guesses from the URL: a CLIProxyAPI base serves all
/// four and only the user knows which one the chosen model answers on.
public enum AgentAPIFormat: String, CaseIterable, Sendable, Codable, Identifiable {
    case openAIChat
    case openAIResponses
    case anthropicMessages
    case googleGenerativeAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAIChat: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        case .googleGenerativeAI: return "Google Generative AI"
        }
    }

    /// The path that lists models, for Save & Validate. Appended to the
    /// base URL the user entered, which stops before any API path.
    public var modelsPath: String {
        switch self {
        case .openAIChat, .openAIResponses, .anthropicMessages: return "v1/models"
        case .googleGenerativeAI: return "v1beta/models"
        }
    }
}

/// One model the user listed for the custom endpoint.
public struct AgentModel: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }

    public var label: String {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespaces), !displayName.isEmpty else { return id }
        return displayName
    }
}

/// A header or query parameter the user adds to every request.
public struct AgentKeyValue: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// Agent mode's own model host, used only by agent mode. Everything but the
/// key lives in UserDefaults as one JSON blob; the key is
/// `KeychainStore.Secret.agentProvider`.
///
/// An enabled override with no selected model is unset, not an error at
/// call time: `AgentEndpoint.resolve` falls through to the dictation route.
public struct AgentProviderOverride: Equatable, Sendable, Codable {
    public var enabled: Bool
    public var baseURL: String
    public var format: AgentAPIFormat
    public var headers: [AgentKeyValue]
    public var queryParameters: [AgentKeyValue]
    public var models: [AgentModel]
    public var selectedModelID: String?

    public init(enabled: Bool = false, baseURL: String = "", format: AgentAPIFormat = .openAIChat,
                headers: [AgentKeyValue] = [], queryParameters: [AgentKeyValue] = [],
                models: [AgentModel] = [], selectedModelID: String? = nil) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.format = format
        self.headers = headers
        self.queryParameters = queryParameters
        self.models = models
        self.selectedModelID = selectedModelID
    }

    public var usableBaseURL: URL? { SettingsStore.usableEndpointURL(baseURL) }

    /// The model the next session runs on, when the override is complete.
    public var selectedModel: AgentModel? {
        guard let selectedModelID else { return nil }
        return models.first { $0.id == selectedModelID }
    }

    /// Complete enough to serve a session.
    public var isActive: Bool { enabled && usableBaseURL != nil && selectedModel != nil }

    /// Rows with a name, trimmed, for the request.
    public static func pairs(_ rows: [AgentKeyValue]) -> [(name: String, value: String)] {
        rows.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, row.value.trimmingCharacters(in: .whitespaces))
        }
    }
}

public extension SettingsStore {
    /// The Agent mode toggle in the Dictation pane.
    var agentModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "agentModeEnabled")
    }

    func setAgentModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "agentModeEnabled")
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "agentModeEnabled")
    }

    var agentProviderOverride: AgentProviderOverride {
        guard let data = UserDefaults.standard.data(forKey: Self.agentProviderOverrideKey),
              let override = try? JSONDecoder().decode(AgentProviderOverride.self, from: data) else {
            return AgentProviderOverride()
        }
        return override
    }

    func setAgentProviderOverride(_ override: AgentProviderOverride) {
        guard let data = try? JSONEncoder().encode(override) else { return }
        UserDefaults.standard.set(data, forKey: Self.agentProviderOverrideKey)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: Self.agentProviderOverrideKey)
    }

    static let agentProviderOverrideKey = "agentProviderOverride"
}
