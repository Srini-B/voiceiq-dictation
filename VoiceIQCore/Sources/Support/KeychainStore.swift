import Foundation
import Security
import VoiceIQBridge

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
        case assemblyAI = "assemblyai-api-key"
        /// The bearer key coding agents send to the local API (`AgentServer`).
        case agentAccess = "agent-access-key"

        var label: String {
            switch self {
            case .assemblyAI: "VoiceiQ — AssemblyAI API key"
            case .agentAccess: "VoiceiQ — coding agent access key"
            }
        }

        /// `object` of `.gtSettingDidChange` when this secret changes.
        public var settingKey: String {
            switch self {
            case .assemblyAI: "apiKey"
            case .agentAccess: "agentAccessKey"
            }
        }
    }

    /// Accounts of the keys older builds stored for OpenAI, ElevenLabs,
    /// Agent mode's custom provider and TinyFish (Ask Anything's web search).
    static let retiredAccounts = ["openai-api-key", "elevenlabs-api-key", "agent-provider-api-key", "tinyfish-api-key"]

    /// Deletes the retired keys; see `SettingsStore.removeRetiredSettingsOnce`.
    public static func deleteRetiredKeys() {
        for account in retiredAccounts where delete(account: account, service: service) {
            Log.permissions.info("KeychainStore: deleted retired \(account, privacy: .public)")
        }
    }

    private static func baseQuery(service: String = service, secret: Secret, dataProtection: Bool) -> [String: Any] {
        baseQuery(service: service, account: secret.rawValue, dataProtection: dataProtection)
    }

    private static func baseQuery(service: String, account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    // MARK: - AssemblyAI

    public static func loadAPIKey() -> String? { load(.assemblyAI, service: service) }

    /// Posts `apiKeySaved` on success, so meetings waiting for AssemblyAI go.
    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        guard save(key, for: .assemblyAI) else { return false }
        NotificationCenter.default.post(name: .apiKeySaved, object: nil)
        return true
    }

    @discardableResult
    public static func deleteAPIKey(notify: Bool = false) -> Bool { delete(.assemblyAI, notify: notify) }

    /// Whether an AssemblyAI key is stored.
    public static var hasModelKey: Bool { loadAPIKey() != nil }

    /// Deletes the Gemini key builds before AssemblyAI stored, here and under
    /// the pre-VoiceiQ service; see `SettingsStore.removeGeminiSettingsOnce`.
    public static func deleteGeminiKey() {
        for service in [service, legacyService] where delete(account: "gemini-api-key", service: service) {
            Log.permissions.info("KeychainStore: deleted the Gemini key")
        }
    }

    // MARK: - Coding agent access

    public static func loadAgentAccessKey() -> String? { load(.agentAccess, service: service) }

    @discardableResult
    public static func saveAgentAccessKey(_ key: String) -> Bool { save(key, for: .agentAccess) }

    // MARK: - Generic

    private static func load(_ secret: Secret, service: String) -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(service: service, secret: secret, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) {
                DebugLog.registerSecret(key)
                return key
            }
        }
        return nil
    }

    private static func save(_ key: String, for secret: Secret) -> Bool {
        DebugLog.registerSecret(key)
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
        delete(account: secret.rawValue, service: service)
    }

    @discardableResult
    private static func delete(account: String, service: String) -> Bool {
        var deleted = false
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(service: service, account: account, dataProtection: dataProtection) as CFDictionary)
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
