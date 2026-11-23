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
/// on-device meeting's notes: Gemini, the on-device writer (LFM3-Omni-2B),
/// or nobody. With the last two the words never leave the device. A Gemini
/// transcript is always written by the rules in the same request.
public enum CleanupSource: String, CaseIterable, Sendable, Identifiable {
    case gemini
    case onDevice
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .onDevice: return "On device"
        case .none: return "Off"
        }
    }

    /// The choices this device offers: On device needs the writer.
    public static var offered: [CleanupSource] {
        allCases.filter { $0 != .onDevice || LocalWriterSupport.isAvailable }
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
    /// the user chose otherwise. On device where this device does not offer
    /// the writer reads as Off, so a local-only choice never turns into Gemini.
    var cleanupSource: CleanupSource {
        let stored = Self.defaults.string(forKey: "cleanupSource").flatMap(CleanupSource.init(rawValue:)) ?? .gemini
        return CleanupSource.offered.contains(stored) ? stored : .none
    }

    /// An on-device dictation or meeting whose model fails, is busy or isn't
    /// downloaded goes to Gemini as audio, as with the Gemini source, unless
    /// writing is Off: then nothing transcribed on device leaves the device.
    var onDeviceFallsBackToGemini: Bool { cleanupSource != .none }

    func setCleanupSource(_ source: CleanupSource) {
        Self.set(source.rawValue, forKey: "cleanupSource")
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
