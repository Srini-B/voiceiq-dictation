import SwiftUI
import VoiceIQSpeech

/// Gemini or this device, chosen apart for dictation, for meetings, and for
/// the writing step of an on-device dictation (and a meeting's notes), with
/// the on-device models' downloads. Shared by the macOS and iOS settings.
@MainActor
public struct SpeechSourceSection<Header: View>: View {
    private let device: String
    private let header: Header
    private let settings = SettingsStore()
    @State private var dictationSource = SettingsStore().dictationSource
    @State private var cleanupSource = SettingsStore().cleanupSource
    @State private var meetingSource = SettingsStore().meetingSource
    @State private var localModel = SettingsStore().localSpeechModel

    /// `device` names this device in the footer ("Mac", "iPhone").
    public init(device: String, @ViewBuilder header: () -> Header) {
        self.device = device
        self.header = header()
    }

    public var body: some View {
        Section {
            // Saved only on a user change, not when a setting reads differently.
            TranscriptionSourcePicker("Dictation", selection: Binding(get: { dictationSource }, set: {
                dictationSource = $0
                settings.setDictationSource($0)
            }))
            TranscriptionSourcePicker("Meetings", selection: Binding(get: { meetingSource }, set: {
                meetingSource = $0
                settings.setMeetingSource($0)
            }))
            if anyOnDevice {
                Picker("Writing rules and notes", selection: Binding(get: { cleanupSource }, set: {
                    cleanupSource = $0
                    settings.setCleanupSource($0)
                })) {
                    ForEach(CleanupSource.offered) { Text($0.displayName).tag($0) }
                }
                .sourcePickerStyle()
            }
            LocalModelControls(localEnabled: dictationSource == .onDevice, meetingsLocal: meetingSource == .onDevice,
                               selection: $localModel)
            LocalMeetingControls(meetingsLocal: meetingSource == .onDevice)
            LocalWriterControls(offered: anyOnDevice && cleanupSource == .onDevice)
        } header: {
            header
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                LocalModelFooter(localEnabled: dictationSource == .onDevice, selection: localModel)
                LocalMeetingFooter(enabled: meetingSource == .onDevice, model: localModel)
                if anyOnDevice {
                    Text(cleanupNote)
                }
            }
        }
        .onChange(of: localModel) { _, model in settings.setLocalSpeechModel(model) }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case "transcriptionSource": dictationSource = settings.dictationSource
            case "meetingTranscriptionSource": meetingSource = settings.meetingSource
            case "cleanupSource": cleanupSource = settings.cleanupSource
            case "onDeviceSpeechModel": localModel = settings.localSpeechModel
            default: break
            }
        }
    }

    private var anyOnDevice: Bool { dictationSource == .onDevice || meetingSource == .onDevice }

    private var cleanupNote: String {
        switch cleanupSource {
        case .gemini: return Self.geminiWrites
        case .onDevice: return "\(LocalWriterSupport.displayName) writes on-device transcripts by your writing rules and writes meeting notes on this \(device). It loads only while it writes. Until it is downloaded, or if an on-device step fails, Gemini takes over when a key is saved."
        case .none: return "Nothing transcribed on device goes to Gemini: dictations go in as transcribed, with your Dictionary's replacements, and meetings keep their transcript with speaker labels but no notes."
        }
    }

    static var geminiWrites: String {
        "On-device transcripts go to Gemini as text, never as audio, to be written by your writing rules, and meetings get notes. If Gemini can't be reached, a dictation goes in as transcribed."
    }
}
