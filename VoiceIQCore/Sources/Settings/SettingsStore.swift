import Foundation

public extension Notification.Name {
    /// Posted after any SettingsStore write and after Keychain API-key writes,
    /// with `object` = the key ("showIdleIndicator", "apiKey", …). Runtime
    /// surfaces that render a setting (pill, status line, hotkey engine) observe
    /// this so toggles take effect the moment they're flipped — never "on the
    /// next unrelated transition".
    static let gtSettingDidChange = Notification.Name("io.blue.voiceiq.setting-changed")
}

/// UserDefaults-backed settings (M3 minimal; the Settings UI lands at M7).
/// Endpoint + model IDs are overridable because preview models get renamed.
public struct SettingsStore: Sendable {
    private static var defaults: UserDefaults { .standard }

    public init() {}

    private static func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        let shown = privateTextKeys.contains(key) ? (value as? String).map { "\($0.count) characters" } ?? "default"
                                                  : logDescription(of: value)
        Log.ui.info("setting \(key, privacy: .public) changed to \(shown)")
        NotificationCenter.default.post(name: .gtSettingDidChange, object: key)
    }

    /// Text the user wrote about themselves or their work, logged by size
    /// only however short it is.
    private static let privateTextKeys: Set<String> = [customWritingRulesKey, "meetingOwnerName"]

    /// Short values as they are; long text, lists and data by size only, so
    /// dictionaries stay out of the log.
    private static func logDescription(of value: Any?) -> String {
        switch value {
        case nil: return "default"
        case let text as String: return text.count <= 80 ? "\"\(text)\"" : "\(text.count) characters"
        case let data as Data: return "\(data.count) bytes"
        case let list as [Any]: return "\(list.count) items"
        case let map as [String: Any]: return "\(map.count) entries"
        case let value?: return String(describing: value)
        }
    }

    /// Single source of truth for endpoint-override validity — the Settings UI
    /// warning and the effective config MUST use the same predicate, or one of
    /// them lies about which endpoint is in use.
    public static func usableEndpointURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    /// True once the user finished onboarding — a deliberate "I'll add it later"
    /// must not re-trap them in the wizard every launch.
    public var hasCompletedOnboarding: Bool {
        Self.defaults.bool(forKey: "hasCompletedOnboarding")
    }

    public func setHasCompletedOnboarding(_ done: Bool) {
        Self.set(done, forKey: "hasCompletedOnboarding")
    }

    public var geminiConfig: GeminiConfig {
        var config = GeminiConfig()
        if let url = Self.usableEndpointURL(Self.defaults.string(forKey: "endpointOverride")) {
            config.endpoint = url
        }
        if let model = Self.defaults.string(forKey: "transcribeModelOverride"), !model.isEmpty {
            config.transcribeModel = model
        }
        if let model = Self.defaults.string(forKey: "cleanupModelOverride"), !model.isEmpty {
            config.writingModel = model
        }
        return config
    }

    /// Runs once, on the first Gemini-only build (0.7.12). Deletes what the
    /// retired providers and modes stored: the OpenAI, ElevenLabs, agent
    /// provider and TinyFish keys in the Keychain, their settings and
    /// shortcuts, and Agent mode's saved runs, which nothing can open any
    /// more. Older builds' on-device settings go too, and so do the toggles
    /// 0.7.12 made permanent (smart transcription, writing rules, spelling,
    /// learning from edits, fitting to existing text, reading names from the
    /// screen, better hearing in loud rooms): each is now always on, and
    /// spelling follows the system region (`SpellingVariant.system`).
    public func removeRetiredSettingsOnce() {
        guard !Self.defaults.bool(forKey: "didRemoveRetiredProviders") else { return }
        Self.defaults.set(true, forKey: "didRemoveRetiredProviders")
        KeychainStore.deleteRetiredKeys()
        for key in Self.retiredKeys { Self.defaults.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: FileLayout.agentRunsRoot)
    }

    static let retiredKeys = [
        "modelProvider", "didAdoptProviderWithKey", "openAITranscribeModelOverride", "openAIWritingModelOverride",
        "liveDictationEnabled", "elevenLabsTranscription", "elevenLabsRedaction", "skipShortDictationCleanup",
        "translationTargetLanguage", "translationTargetLanguages", "agentProviderOverride", "agentModeEnabled",
        "shortcut.askAnything", "shortcut.translate", "shortcut.agent",
        "dictationSource", "meetingSource", "localTranscriptionEnabled", "localMeetingTranscriptionEnabled",
        "localSpeechModel", "localSpeechLanguage", "writingSource", "localWriterModel",
        "smartTranscription", "smartCleanupPass", "spellingVariant", "autoLearn", "fitToExistingText",
        "meetingScreenNames", "experimentalNoiseHandling", "smartFormatting", "gateTrips", "shouldAnnounceSmartRestored",
        "didMigrateSmartFormattingKeys", "didEnableWritingRules", "didRestoreAutoDegradedWritingRules",
    ]

    /// The languages the user speaks, as ISO 639-3 codes from
    /// `SpokenLanguage.all`: the first is the main language and the rest are
    /// the others it may hear. Empty detects the language. Dictation gets them
    /// as a hint (`SpokenLanguage.promptLine`).
    /// Codes typed into the earlier free-text field read as their
    /// three-letter form ("hi" as "hin"); ones not listed are dropped.
    public var spokenLanguages: [String] {
        (Self.defaults.stringArray(forKey: "spokenLanguages") ?? []).map { code in
            code.count == 2 ? Locale.LanguageCode(code).identifier(.alpha3) ?? code : code
        }.filter(SpokenLanguage.isListed)
    }

    /// Main language first; each code once. Empty is automatic detection.
    public func setSpokenLanguages(_ codes: [String]) {
        var seen = Set<String>()
        Self.set(codes.filter { seen.insert($0).inserted }, forKey: "spokenLanguages")
    }

    /// Show the resting dot at the bottom of the screen when idle. Off = the pill
    /// only appears while dictating. Off by default since 2026-11-12, the
    /// owner's choice; it was on before. A user who set the toggle keeps it.
    public var showIdleIndicator: Bool {
        Self.defaults.object(forKey: "showIdleIndicator") as? Bool ?? false
    }

    public func setShowIdleIndicator(_ show: Bool) {
        Self.set(show, forKey: "showIdleIndicator")
    }

    /// Keep the pill out of screen shares and recordings of the whole screen,
    /// so a shared screen does not show that a meeting is being recorded.
    public var hidePillFromScreenSharing: Bool {
        Self.defaults.object(forKey: "hidePillFromScreenSharing") as? Bool ?? true
    }

    public func setHidePillFromScreenSharing(_ hide: Bool) {
        Self.set(hide, forKey: "hidePillFromScreenSharing")
    }

    public var soundsEnabled: Bool {
        Self.defaults.object(forKey: "soundsEnabled") as? Bool ?? true
    }

    public func setSoundsEnabled(_ enabled: Bool) {
        Self.set(enabled, forKey: "soundsEnabled")
    }

    /// Where the pill sits along the bottom of the screen, as a fraction of the
    /// visible width: 0 far left, 0.5 centre, 1 far right. Snapped to five
    /// stops so a drag ends somewhere predictable.
    public static let pillAnchors: [Double] = [0, 0.25, 0.5, 0.75, 1]

    public var pillAnchor: Double {
        Self.defaults.object(forKey: "pillAnchor") as? Double ?? 0.5
    }

    public func setPillAnchor(_ fraction: Double) {
        let nearest = Self.pillAnchors.min(by: { abs($0 - fraction) < abs($1 - fraction) }) ?? 0.5
        Self.set(nearest, forKey: "pillAnchor")
    }

    public var muteOtherAudioWhileDictating: Bool {
        Self.defaults.object(forKey: "muteOtherAudioWhileDictating") as? Bool ?? true
    }

    public func setMuteOtherAudioWhileDictating(_ enabled: Bool) {
        Self.set(enabled, forKey: "muteOtherAudioWhileDictating")
    }

    /// Pause Music and Spotify while dictating, and play them again after.
    /// Off by default: the first pause asks to control the player.
    public var pauseMediaWhileDictating: Bool {
        Self.defaults.bool(forKey: "pauseMediaWhileDictating")
    }

    public func setPauseMediaWhileDictating(_ enabled: Bool) {
        Self.set(enabled, forKey: "pauseMediaWhileDictating")
    }

    /// On unless the user turned it off. Read from the stored value only when
    /// one exists, so an explicit Off survives and every install that never
    /// touched the toggle gets the default with no migration write.
    public var copyRecoveredToClipboard: Bool {
        Self.defaults.object(forKey: "copyRecoveredToClipboard") as? Bool ?? true
    }

    public func setCopyRecoveredToClipboard(_ enabled: Bool) {
        Self.set(enabled, forKey: "copyRecoveredToClipboard")
    }

    /// Off by default since 2026-10-13: three screenshots add about 1.3 s to
    /// every cleanup (measured 2.4 s → 3.7 s). The app and window names go
    /// with the transcript instead, at no cost.
    public var screenContextEnabled: Bool {
        Self.defaults.object(forKey: "screenContextEnabled") as? Bool ?? false
    }

    public func setScreenContextEnabled(_ enabled: Bool) {
        Self.set(enabled, forKey: "screenContextEnabled")
    }

    public var preferredInputDeviceUID: String? {
        Self.defaults.string(forKey: "preferredInputDeviceUID")
    }

    public func setPreferredInputDeviceUID(_ uid: String?) {
        Self.set(uid, forKey: "preferredInputDeviceUID")
    }

    /// The dictation key. `dictationTrigger` (JSON) wins; installs from before
    /// combos were allowed still carry the bare key under `hotkeyKey`.
    public var dictationTrigger: DictationTrigger {
        if let data = Self.defaults.data(forKey: "dictationTrigger"),
           let trigger = try? JSONDecoder().decode(DictationTrigger.self, from: data) {
            return trigger
        }
        if let key = Self.defaults.string(forKey: "hotkeyKey").flatMap(HotkeyKey.init(rawValue:)) {
            return .modifier(key)
        }
        return .default
    }

    /// Rules the user adds on top of `DefaultWritingRules`. Empty when there
    /// are none.
    public var customWritingRules: String {
        Self.defaults.string(forKey: Self.customWritingRulesKey) ?? ""
    }

    /// Stores an edit and stamps it for `WritingRulesSync`. Unchanged text is
    /// not stamped: the iPhone editor saves on every close, and a fresh stamp
    /// would let an untouched copy win over a real edit on the Mac.
    public func setCustomWritingRules(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        guard value != Self.defaults.string(forKey: Self.customWritingRulesKey) else { return }
        Self.defaults.set(Date(), forKey: Self.customWritingRulesUpdatedAtKey)
        Self.set(value, forKey: Self.customWritingRulesKey)
    }

    public static let customWritingRulesKey = "customWritingRules"
    static let customWritingRulesUpdatedAtKey = "customWritingRulesUpdatedAt"

    /// The custom rules as `WritingRulesSync` sees them. Rules that were never
    /// stamped count as the oldest possible edit.
    public var writingRulesSnapshot: WritingRulesSnapshot {
        WritingRulesSnapshot(
            text: Self.defaults.string(forKey: Self.customWritingRulesKey),
            updatedAt: Self.defaults.object(forKey: Self.customWritingRulesUpdatedAtKey) as? Date ?? .distantPast
        )
    }

    public func applySyncedWritingRules(_ snapshot: WritingRulesSnapshot) {
        Self.defaults.set(snapshot.updatedAt, forKey: Self.customWritingRulesUpdatedAtKey)
        Self.set(snapshot.text, forKey: Self.customWritingRulesKey)
    }

    /// Detect calls (mic in use by a call app or a meeting tab) and record
    /// them for meeting notes.
    public var meetingDetectionEnabled: Bool {
        Self.defaults.object(forKey: "meetingDetection") as? Bool ?? true
    }

    public func setMeetingDetection(_ enabled: Bool) {
        Self.set(enabled, forKey: "meetingDetection")
    }

    /// The note owner's name in meeting notes, which are shared, so the owner
    /// is never "You" there. The Mac defaults to the account's full name.
    public var meetingOwnerName: String {
        if let name = Self.defaults.string(forKey: "meetingOwnerName") { return name }
        #if os(macOS)
        return NSFullUserName()
        #else
        return ""
        #endif
    }

    public func setMeetingOwnerName(_ name: String) {
        Self.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "meetingOwnerName")
    }

    public func setDictationTrigger(_ trigger: DictationTrigger) {
        Self.set(try? JSONEncoder().encode(trigger), forKey: "dictationTrigger")
    }

    // Raw override values for the Settings UI — panes must not duplicate the
    // defaults keys (a rename would silently desync display from effect).
    public var endpointOverride: String? { Self.defaults.string(forKey: "endpointOverride") }
    public var transcribeModelOverride: String? { Self.defaults.string(forKey: "transcribeModelOverride") }
    public var cleanupModelOverride: String? { Self.defaults.string(forKey: "cleanupModelOverride") }

    public func setEndpointOverride(_ raw: String?) {
        Self.set(raw, forKey: "endpointOverride")
    }

    public func setTranscribeModelOverride(_ raw: String?) {
        Self.set(raw, forKey: "transcribeModelOverride")
    }

    public func setCleanupModelOverride(_ raw: String?) {
        Self.set(raw, forKey: "cleanupModelOverride")
    }

    /// Days to keep audio files (transcripts are kept until deleted). 0 = forever.
    public var audioRetentionDays: Int {
        Self.defaults.object(forKey: "audioRetentionDays") as? Int ?? 7
    }

    public func setAudioRetentionDays(_ days: Int) {
        Self.set(days, forKey: "audioRetentionDays")
    }

    /// Days to keep finished dictations in History, with their folders.
    /// 0 = forever (the default), -1 = never: a dictation is removed as soon
    /// as it has landed. Rows that still need attention (a failed upload
    /// waiting for Retry, text held for a secure field) are kept either way.
    public var transcriptRetentionDays: Int {
        Self.defaults.object(forKey: "transcriptRetentionDays") as? Int ?? 0
    }

    public func setTranscriptRetentionDays(_ days: Int) {
        Self.set(days, forKey: "transcriptRetentionDays")
    }

    /// Lets coding agents on this Mac read History and meetings through the
    /// local API and MCP server (`AgentServer`). Off until the user turns it on.
    public var agentAccessEnabled: Bool {
        Self.defaults.bool(forKey: "agentAccessEnabled")
    }

    public func setAgentAccessEnabled(_ enabled: Bool) {
        Self.set(enabled, forKey: "agentAccessEnabled")
    }
}
