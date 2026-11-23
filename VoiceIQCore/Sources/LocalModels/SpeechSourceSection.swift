import SwiftUI
import VoiceIQSpeech

/// Gemini or this device, chosen apart for dictation, for meetings, and for
/// the writing step of an on-device dictation (and a meeting's notes), then
/// the on-device models grouped by their job: transcription, the English
/// add-on, and writing. Shared by the macOS and iOS settings.
///
/// A group shows while its choice is On device. Otherwise it shows only while
/// one of its models is on disk or downloading, so it can still be deleted
/// or cancelled.
@MainActor
public struct SpeechSourceSection<Header: View>: View {
    private let device: String
    private let header: (String) -> Header
    private let settings = SettingsStore()
    @State private var dictationSource = SettingsStore().dictationSource
    @State private var cleanupSource = SettingsStore().cleanupSource
    @State private var meetingSource = SettingsStore().meetingSource
    @State private var localModel = SettingsStore().localSpeechModel
    @ObservedObject private var mini = LocalModelStore.store(for: .parakeet)
    @ObservedObject private var pro = LocalModelStore.store(for: .fluidSpeechPro)
    @ObservedObject private var diarizer = LocalModelStore.speakerDiarizer
    @ObservedObject private var englishTools = LocalModelStore.englishTools
    @ObservedObject private var writer = LocalModelStore.writer

    /// `device` names this device in the footer ("Mac", "iPhone"); `header`
    /// draws each section's title.
    public init(device: String, @ViewBuilder header: @escaping (String) -> Header) {
        self.device = device
        self.header = header
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
        } header: {
            header("Speech")
        } footer: {
            if !LocalModelSupport.isAvailable {
                Text(LocalModelSupport.requirement)
            } else if anyOnDevice, cleanupSource != .onDevice {
                Text(cleanupNote)
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

        if LocalModelSupport.isAvailable {
            if shows(speechModels, offered: anyOnDevice) || shows([diarizer], offered: meetingsLocal) {
                Section {
                    LocalModelControls(localEnabled: dictationLocal, meetingsLocal: meetingsLocal, selection: $localModel)
                    LocalModelRow(store: diarizer, offered: meetingsLocal, selection: nil)
                } header: {
                    header("On-device transcription")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transcriptionNote)
                        LocalModelFooter(localEnabled: dictationLocal, selection: localModel)
                        LocalMeetingFooter(enabled: meetingsLocal, model: localModel)
                    }
                }
            }
            if shows([englishTools], offered: dictationLocal) {
                Section {
                    LocalModelRow(store: englishTools, offered: dictationLocal, selection: nil)
                } header: {
                    header("Add-on for English dictation")
                } footer: {
                    Text(dictationLocal ? "Dictionary correction for English on-device dictation. Without it, on-device transcription still works."
                                       : "Not used while Dictation is set to Gemini.")
                }
            }
            if shows([writer], offered: writesOnDevice) {
                Section {
                    LocalModelRow(store: writer, offered: writesOnDevice, selection: nil)
                } header: {
                    header("On-device writing")
                } footer: {
                    Text(writesOnDevice ? cleanupNote : "Not used while Writing rules and notes is not set to On device.")
                }
            }
        }
    }

    private var dictationLocal: Bool { dictationSource == .onDevice }
    private var meetingsLocal: Bool { meetingSource == .onDevice }
    private var anyOnDevice: Bool { dictationLocal || meetingsLocal }
    private var writesOnDevice: Bool { anyOnDevice && cleanupSource == .onDevice }

    private var speechModels: [LocalModelStore] { LocalSpeechModel.available.map(LocalModelStore.store(for:)) }

    /// Whether any of `stores` has a row: offered, or with something on disk
    /// or in transit.
    private func shows(_ stores: [LocalModelStore], offered: Bool) -> Bool {
        stores.contains { LocalModelRow.isVisible($0.state, offered: offered) }
    }

    private var transcriptionNote: String {
        switch (dictationLocal, meetingsLocal) {
        case (true, true): return "Dictation and meetings use the checked model. Speaker Separation tells meeting speakers apart."
        case (true, false): return "Dictation uses the checked model, in the language picked under it."
        case (false, true): return "Meetings use the checked model, and Speaker Separation tells speakers apart."
        case (false, false): return "Not used while Dictation and Meetings are set to Gemini."
        }
    }

    private var cleanupNote: String {
        switch cleanupSource {
        case .gemini: return Self.geminiWrites
        case .onDevice: return "\(LocalWriterSupport.displayName) writes on-device transcripts by your writing rules and writes meeting notes on this \(device). It loads only while it writes. Until it is downloaded, or if an on-device step fails, Gemini takes over when a key is saved."
        case .none: return "No writing step: dictations go in as transcribed, with your Dictionary's replacements, and meetings keep their transcript with speaker labels but no notes. If an on-device model is missing or fails, Gemini transcribes the recording when a key is saved."
        }
    }

    static var geminiWrites: String {
        "On-device transcripts go to Gemini as text, never as audio, to be written by your writing rules, and meetings get notes. If Gemini can't be reached, a dictation goes in as transcribed."
    }
}
