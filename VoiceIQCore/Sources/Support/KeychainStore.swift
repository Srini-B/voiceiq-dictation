import Foundation
import Security

/// API-key storage per TN3137: SecItem + data-protection keychain when the build
/// carries the keychain-access-groups entitlement (provisioned/notarized builds),
/// with a graceful fallback to the login keychain for dev and fork builds that
/// lack it (errSecMissingEntitlement, -34018). Never UserDefaults/JSON
/// (Superwhisper's documented failure).
public enum KeychainStore {
    private static let service = "io.blue.voiceiq"
    private static let legacyService = "com.ammaar.jot"

    /// One keychain item per secret. `rawValue` is the `kSecAttrAccount`.
    public enum Secret: String {
        case gemini = "gemini-api-key"
        case tinyFish = "tinyfish-api-key"
        case openRouter = "openrouter-api-key"
        case vercel = "vercel-ai-gateway-key"
        case openAI = "openai-api-key"
        case elevenLabs = "elevenlabs-api-key"
        case sarvam = "sarvam-api-key"
        case agentProvider = "agent-provider-api-key"

        var label: String {
            switch self {
            case .gemini: return "VoiceiQ — Gemini API key"
            case .tinyFish: return "VoiceiQ — TinyFish API key"
            case .openRouter: return "VoiceiQ — OpenRouter API key"
            case .vercel: return "VoiceiQ — Vercel AI Gateway key"
            case .openAI: return "VoiceiQ — OpenAI API key"
            case .elevenLabs: return "VoiceiQ — ElevenLabs API key"
            case .sarvam: return "VoiceiQ — Sarvam API key"
            case .agentProvider: return "VoiceiQ — Agent provider API key"
            }
        }

        /// `object` of `.gtSettingDidChange` when this secret changes.
        public var settingKey: String {
            switch self {
            case .gemini: return "apiKey"
            case .tinyFish: return "tinyFishKey"
            case .openRouter: return "openRouterKey"
            case .vercel: return "vercelKey"
            case .openAI: return "openAIKey"
            case .elevenLabs: return "elevenLabsKey"
            case .sarvam: return "sarvamKey"
            case .agentProvider: return "agentProviderKey"
            }
        }
    }

    // MARK: - Agent provider override

    public static func loadAgentProviderKey() -> String? { load(.agentProvider, service: service) }

    @discardableResult
    public static func saveAgentProviderKey(_ key: String) -> Bool { save(key, for: .agentProvider) }

    @discardableResult
    public static func deleteAgentProviderKey(notify: Bool = false) -> Bool { delete(.agentProvider, notify: notify) }

    private static func baseQuery(service: String = service, secret: Secret, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    // MARK: - Gemini

    public static func loadAPIKey() -> String? {
        if let key = load(.gemini, service: service) { return key }
        guard let legacyKey = load(.gemini, service: legacyService) else { return nil }
        if saveAPIKey(legacyKey) {
            delete(.gemini, service: legacyService)
            Log.permissions.info("KeychainStore: migrated API key to VoiceiQ service")
        }
        return legacyKey
    }

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool { save(key, for: .gemini) }

    @discardableResult
    public static func deleteAPIKey(notify: Bool = false) -> Bool { delete(.gemini, notify: notify) }

    // MARK: - TinyFish

    public static func loadTinyFishKey() -> String? { load(.tinyFish, service: service) }

    @discardableResult
    public static func saveTinyFishKey(_ key: String) -> Bool { save(key, for: .tinyFish) }

    @discardableResult
    public static func deleteTinyFishKey(notify: Bool = false) -> Bool { delete(.tinyFish, notify: notify) }

    // MARK: - OpenRouter

    public static func loadOpenRouterKey() -> String? { load(.openRouter, service: service) }

    @discardableResult
    public static func saveOpenRouterKey(_ key: String) -> Bool { save(key, for: .openRouter) }

    @discardableResult
    public static func deleteOpenRouterKey(notify: Bool = false) -> Bool { delete(.openRouter, notify: notify) }

    // MARK: - Vercel AI Gateway

    public static func loadVercelKey() -> String? { load(.vercel, service: service) }

    @discardableResult
    public static func saveVercelKey(_ key: String) -> Bool { save(key, for: .vercel) }

    @discardableResult
    public static func deleteVercelKey(notify: Bool = false) -> Bool { delete(.vercel, notify: notify) }

    // MARK: - OpenAI

    public static func loadOpenAIKey() -> String? { load(.openAI, service: service) }

    @discardableResult
    public static func saveOpenAIKey(_ key: String) -> Bool { save(key, for: .openAI) }

    @discardableResult
    public static func deleteOpenAIKey(notify: Bool = false) -> Bool { delete(.openAI, notify: notify) }

    // MARK: - ElevenLabs

    public static func loadElevenLabsKey() -> String? { load(.elevenLabs, service: service) }

    @discardableResult
    public static func saveElevenLabsKey(_ key: String) -> Bool { save(key, for: .elevenLabs) }

    @discardableResult
    public static func deleteElevenLabsKey(notify: Bool = false) -> Bool { delete(.elevenLabs, notify: notify) }

    // MARK: - Sarvam

    public static func loadSarvamKey() -> String? { load(.sarvam, service: service) }

    @discardableResult
    public static func saveSarvamKey(_ key: String) -> Bool { save(key, for: .sarvam) }

    @discardableResult
    public static func deleteSarvamKey(notify: Bool = false) -> Bool { delete(.sarvam, notify: notify) }

    /// Whether the provider's own key is stored.
    public static func hasDirectKey(for provider: ModelProvider) -> Bool {
        switch provider {
        case .gemini: return loadAPIKey() != nil
        case .openAI: return loadOpenAIKey() != nil
        }
    }

    /// The gateways that can reach `provider` right now. A gateway key serves
    /// both providers; the direct route needs the provider's own key.
    public static func gatewaysWithKeys(for provider: ModelProvider) -> Set<ModelGateway> {
        var set = Set<ModelGateway>()
        if hasDirectKey(for: provider) { set.insert(.direct) }
        if loadOpenRouterKey() != nil { set.insert(.openRouter) }
        if loadVercelKey() != nil { set.insert(.vercel) }
        return set
    }

    /// Whether the selected provider can be reached at all. This is what "the
    /// app can transcribe" means; a Gemini key alone does not let an OpenAI
    /// selection transcribe.
    public static var hasModelKey: Bool { !gatewaysWithKeys(for: SettingsStore().preferredProvider).isEmpty }

    // MARK: - Generic

    private static func load(_ secret: Secret, service: String) -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(service: service, secret: secret, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private static func save(_ key: String, for secret: Secret) -> Bool {
        delete(secret, service: service)
        for dataProtection in [true, false] {
            var attributes = baseQuery(secret: secret, dataProtection: dataProtection)
            attributes[kSecAttrLabel as String] = secret.label
            attributes[kSecValueData as String] = Data(key.utf8)
            if dataProtection {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecSuccess {
                Log.permissions.info("KeychainStore: \(secret.rawValue, privacy: .public) saved (\(dataProtection ? "data-protection" : "login", privacy: .public) keychain)")
                NotificationCenter.default.post(name: .gtSettingDidChange, object: secret.settingKey)
                return true
            }
            if status != errSecMissingEntitlement {
                Log.permissions.error("KeychainStore: save failed (\(status))")
                return false
            }
            // -34018: unprovisioned build — fall through to the login keychain.
        }
        return false
    }

    private static func delete(_ secret: Secret, notify: Bool) -> Bool {
        let deleted = delete(secret, service: service)
        if deleted, notify {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: secret.settingKey)
        }
        return deleted
    }

    @discardableResult
    private static func delete(_ secret: Secret, service: String) -> Bool {
        var deleted = false
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(service: service, secret: secret, dataProtection: dataProtection) as CFDictionary)
            deleted = deleted || status == errSecSuccess
        }
        return deleted
    }

    #if os(macOS)
    /// Dev bootstrap until onboarding (M7): if ~/.config/voiceiq/apikey.dev
    /// exists, migrate its contents into the Keychain and DELETE the file. Lets
    /// contributors seed a key without any UI, without leaving plaintext behind.
    public static func migrateDevKeyFileIfPresent() {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voiceiq/apikey.dev")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if saveAPIKey(key) {
            try? FileManager.default.removeItem(at: fileURL)
            Log.permissions.info("KeychainStore: migrated dev key file into Keychain (file deleted)")
        }
    }
    #endif
}
