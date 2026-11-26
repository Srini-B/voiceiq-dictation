import Foundation
import VoiceIQSpeech

/// Who turns audio into text, for dictation or for meetings: Gemini (the
/// default) or a Fluid Speech model on this device.
public enum TranscriptionSource: String, CaseIterable, Sendable, Identifiable {
    case gemini
    case onDevice

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .onDevice: return "On device"
        }
    }
}

/// Who applies the writing rules to an on-device transcript and writes an
/// on-device meeting's notes: Gemini, or nobody, so the words never leave the
/// device. With Off, a dictation is tidied on the device (`TidyStyle`). A
/// Gemini transcript is always written by the rules in the same request.
public enum CleanupSource: String, CaseIterable, Sendable, Identifiable {
    case gemini
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .none: return "Off"
        }
    }
}

public extension SettingsStore {
    /// Who transcribes dictation. On a device without local models it reads
    /// as Gemini.
    var dictationSource: TranscriptionSource { source(forKey: "transcriptionSource") }

    func setDictationSource(_ source: TranscriptionSource) {
        Self.set(source.rawValue, forKey: "transcriptionSource")
    }

    var localTranscriptionEnabled: Bool { dictationSource == .onDevice }

    /// Who transcribes meetings. On device needs the selected model and the
    /// speaker separation model downloaded; without them a meeting goes to Gemini.
    var meetingSource: TranscriptionSource { source(forKey: "meetingTranscriptionSource") }

    func setMeetingSource(_ source: TranscriptionSource) {
        Self.set(source.rawValue, forKey: "meetingTranscriptionSource")
    }

    var localMeetingTranscriptionEnabled: Bool { meetingSource == .onDevice }

    /// Who applies the writing rules to an on-device dictation. Gemini unless
    /// the user chose Off. "onDevice", stored by 0.7.15 and earlier for the
    /// retired on-device writer, reads as Off, so a local-only choice never
    /// turns into Gemini.
    var cleanupSource: CleanupSource {
        switch Self.defaults.string(forKey: "cleanupSource") {
        case "onDevice": return .none
        case let stored: return stored.flatMap(CleanupSource.init(rawValue:)) ?? .gemini
        }
    }

    func setCleanupSource(_ source: CleanupSource) {
        Self.set(source.rawValue, forKey: "cleanupSource")
    }

    /// How an on-device dictation is tidied while writing is Off.
    var tidyStyle: TidyStyle {
        Self.defaults.string(forKey: "tidyStyle").flatMap(TidyStyle.init(rawValue:)) ?? .sentences
    }

    func setTidyStyle(_ style: TidyStyle) {
        Self.set(style.rawValue, forKey: "tidyStyle")
    }

    /// The on-device model to download and use. An unknown value, or one this
    /// device does not offer (Pro on an iPhone under 6 GB), reads as the
    /// first model it offers.
    var localSpeechModel: LocalSpeechModel {
        let stored = Self.defaults.string(forKey: "onDeviceSpeechModel").flatMap(LocalSpeechModel.init(stored:))
        guard let stored, LocalSpeechModel.available.contains(stored) else { return LocalSpeechModel.available[0] }
        return stored
    }

    func setLocalSpeechModel(_ model: LocalSpeechModel) {
        guard model != localSpeechModel else { return }
        Self.set(model.rawValue, forKey: "onDeviceSpeechModel")
    }

    /// The language the on-device model transcribes. A stored code the
    /// selected model lacks (German, then Fluid Speech Mini) reads as English,
    /// and comes back when that model is picked again.
    var localSpeechLanguage: LocalSpeechLanguage {
        localSpeechModel.language(code: localSpeechLanguageCode)
    }

    /// The stored code as chosen, which the selected model may not offer.
    var localSpeechLanguageCode: String? {
        Self.defaults.string(forKey: "onDeviceSpeechLanguage")
    }

    func setLocalSpeechLanguage(_ code: String) {
        Self.set(code, forKey: "onDeviceSpeechLanguage")
    }

    private func source(forKey key: String) -> TranscriptionSource {
        let stored = Self.defaults.string(forKey: key).flatMap(TranscriptionSource.init(rawValue:)) ?? .gemini
        return LocalModelSupport.isAvailable ? stored : .gemini
    }
}
