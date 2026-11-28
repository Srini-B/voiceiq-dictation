import SwiftUI
import VoiceIQSpeech

/// AssemblyAI or this device for dictation (meetings always use AssemblyAI), then
/// AssemblyAI or Off for the writing step of an on-device dictation, with how an
/// unwritten dictation is tidied, then the on-device models grouped by their
/// job: transcription, meeting speakers, and the English add-on. Shared by
/// the macOS and iOS settings.
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
    @State private var tidyStyle = SettingsStore().tidyStyle
    @State private var localModel = SettingsStore().localSpeechModel
    @ObservedObject private var mini = LocalModelStore.store(for: .parakeet)
    @ObservedObject private var pro = LocalModelStore.store(for: .fluidSpeechPro)
    @ObservedObject private var diarizer = LocalModelStore.speakerDiarizer
    @ObservedObject private var englishTools = LocalModelStore.englishTools

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
            if anyOnDevice {
                Picker("Writing rules", selection: Binding(get: { cleanupSource }, set: {
                    cleanupSource = $0
                    settings.setCleanupSource($0)
                })) {
                    ForEach(CleanupSource.allCases) { Text($0.displayName).tag($0) }
                }
                .sourcePickerStyle()
            }
            if tidies {
                Picker("Tidy dictation", selection: Binding(get: { tidyStyle }, set: {
                    tidyStyle = $0
                    settings.setTidyStyle($0)
                })) {
                    ForEach(TidyStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .sourcePickerStyle()
            }
        } header: {
            header("Speech")
        } footer: {
            if !LocalModelSupport.isAvailable {
                Text(LocalModelSupport.requirement)
            } else if anyOnDevice {
                Text(cleanupNote)
            }
        }
        .onChange(of: localModel) { _, model in settings.setLocalSpeechModel(model) }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            switch note.object as? String {
            case "transcriptionSource": dictationSource = settings.dictationSource
            case "cleanupSource": cleanupSource = settings.cleanupSource
            case "tidyStyle": tidyStyle = settings.tidyStyle
            case "onDeviceSpeechModel": localModel = settings.localSpeechModel
            default: break
            }
        }

        if LocalModelSupport.isAvailable {
            if shows(speechModels, offered: anyOnDevice) {
                Section {
                    LocalModelControls(localEnabled: dictationLocal, selection: $localModel)
                } header: {
                    header("On-device transcription")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dictationLocal ? "Dictation uses the checked model, in the language picked under it."
                                            : "Not used while Dictation is set to AssemblyAI.")
                        LocalModelFooter(localEnabled: dictationLocal, selection: localModel)
                    }
                }
            }
            if shows([diarizer], offered: false) {
                Section {
                    LocalModelRow(store: diarizer, offered: false, selection: nil)
                } header: {
                    header("Meeting speakers")
                } footer: {
                    Text("Tells the other people on a call apart, on this \(device). AssemblyAI transcribes every meeting; this model is downloaded for it without asking.")
                }
            }
            if shows([englishTools], offered: dictationLocal) {
                Section {
                    LocalModelRow(store: englishTools, offered: dictationLocal, selection: nil)
                } header: {
                    header("Add-on for English dictation")
                } footer: {
                    Text(dictationLocal ? "Dictionary correction for English on-device dictation. Without it, on-device transcription still works."
                                       : "Not used while Dictation is set to AssemblyAI.")
                }
            }
        }
    }

    private var dictationLocal: Bool { dictationSource == .onDevice }
    private var anyOnDevice: Bool { dictationLocal }
    /// An on-device dictation goes in without a writing step, so it is tidied.
    private var tidies: Bool { dictationLocal && cleanupSource == .none }

    private var speechModels: [LocalModelStore] { LocalSpeechModel.available.map(LocalModelStore.store(for:)) }

    /// Whether any of `stores` has a row: offered, or with something on disk
    /// or in transit.
    private func shows(_ stores: [LocalModelStore], offered: Bool) -> Bool {
        stores.contains { LocalModelRow.isVisible($0.state, offered: offered) }
    }

    private var cleanupNote: String {
        switch cleanupSource {
        case .assemblyAI: return Self.assemblyAIWrites
        case .none:
            let marks = tidyStyle == .asSpoken ? "" : " Say \"new line\" or \"comma\" for the mark."
            let dictation = dictationLocal
                ? " Dictations are tidied on this \(device) with your Dictionary's replacements. \(tidyStyle.summary)\(marks)"
                : ""
            return "No writing step.\(dictation) If the on-device model is missing or fails, AssemblyAI transcribes the recording."
        }
    }

    static var assemblyAIWrites: String {
        "On-device transcripts go to AssemblyAI as text, never as audio, to be written by your writing rules. If AssemblyAI can't be reached, a dictation goes in as transcribed."
    }
}
