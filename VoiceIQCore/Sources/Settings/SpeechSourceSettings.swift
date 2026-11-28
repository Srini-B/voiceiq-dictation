import Foundation
import VoiceIQSpeech

/// Who turns dictation into text: AssemblyAI (the default) or a Fluid Speech
/// model on this device. AssemblyAI's raw value is "gemini", the provider
/// builds before 0.7.19 stored, so the choice carries over.
public enum TranscriptionSource: String, CaseIterable, Sendable, Identifiable {
    case assemblyAI = "gemini"
    case onDevice

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .onDevice: return "On device"
        }
    }
}

/// Who applies the writing rules to a dictation: the writing model on
/// AssemblyAI's LLM Gateway, or nobody, so an on-device transcript never
/// leaves the device. With Off, a dictation is tidied on the device
/// (`TidyStyle`). The raw value "gemini" is what builds before 0.7.19 stored.
public enum CleanupSource: String, CaseIterable, Sendable, Identifiable {
    case assemblyAI = "gemini"
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .assemblyAI: return "AssemblyAI"
        case .none: return "Off"
        }
    }
}

public extension SettingsStore {
    /// Who transcribes dictation. On a device without local models it reads
    /// as AssemblyAI.
    var dictationSource: TranscriptionSource { source(forKey: "transcriptionSource") }

    func setDictationSource(_ source: TranscriptionSource) {
        Self.set(source.rawValue, forKey: "transcriptionSource")
    }

    var localTranscriptionEnabled: Bool { dictationSource == .onDevice }

    /// Who applies the writing rules to a dictation. AssemblyAI unless the
    /// user chose Off. "onDevice", stored by 0.7.15 and earlier for the
    /// retired on-device writer, reads as Off, so a local-only choice never
    /// turns into a cloud call.
    var cleanupSource: CleanupSource {
        switch Self.defaults.string(forKey: "cleanupSource") {
        case "onDevice": return .none
        case let stored: return stored.flatMap(CleanupSource.init(rawValue:)) ?? .assemblyAI
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
        let stored = Self.defaults.string(forKey: key).flatMap(TranscriptionSource.init(rawValue:)) ?? .assemblyAI
        return LocalModelSupport.isAvailable ? stored : .assemblyAI
    }
}
