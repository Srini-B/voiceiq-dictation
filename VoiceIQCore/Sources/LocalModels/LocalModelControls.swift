import SwiftUI
import VoiceIQSpeech

/// The model list shared by the macOS and iOS settings. While on-device
/// transcription is on, every model has a row: the leading check selects it,
/// and the trailing action downloads, cancels, or deletes that model alone.
/// While it is off, only models on disk or in transit keep a row, so they can
/// still be cancelled or deleted. The English tools pack follows the same
/// rules but is never selected. The selected model also transcribes meetings
/// kept on device, so the rows stay offered and selectable while that is on.
@MainActor
public struct LocalModelControls: View {
    private let localEnabled: Bool
    private let meetingsLocal: Bool
    @Binding private var selection: LocalSpeechModel
    /// The stored code, kept as is: the picker shows the selected model's
    /// reading of it, so switching models does not lose a choice.
    @State private var languageCode = SettingsStore().localSpeechLanguageCode

    public init(localEnabled: Bool, meetingsLocal: Bool = false, selection: Binding<LocalSpeechModel>) {
        self.localEnabled = localEnabled
        self.meetingsLocal = meetingsLocal
        _selection = selection
    }

    public var body: some View {
        if LocalModelSupport.isAvailable {
            ForEach(LocalSpeechModel.available, id: \.self) { model in
                LocalModelRow(
                    store: .store(for: model),
                    offered: localEnabled || meetingsLocal,
                    selection: localEnabled || meetingsLocal ? (isSelected: model == selection, select: { selection = model }) : nil,
                    languages: model.languages,
                    language: localEnabled && model == selection ? languageBinding(for: model) : nil
                )
            }
            LocalModelRow(store: .englishTools, offered: localEnabled, selection: nil)
            if localEnabled {
                Text(Self.englishNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func languageBinding(for model: LocalSpeechModel) -> Binding<String> {
        Binding(
            get: { model.language(code: languageCode).code },
            set: { code in
                languageCode = code
                SettingsStore().setLocalSpeechLanguage(code)
            }
        )
    }

    static let englishNote = "English tools add dictionary correction for English dictation. Without them, on-device transcription still works."
}

/// The speaker diarizer's row, offered while meetings are kept on device.
/// Nothing on iPhone and iPad, which transcribe meetings without a diarizer.
@MainActor
public struct LocalMeetingControls: View {
    private let meetingsLocal: Bool

    public init(meetingsLocal: Bool) {
        self.meetingsLocal = meetingsLocal
    }

    public var body: some View {
        if LocalModelSupport.isAvailable, LocalMeetingTranscriber.diarizes {
            LocalModelRow(store: .speakerDiarizer, offered: meetingsLocal, selection: nil)
        }
    }
}

@MainActor
struct LocalModelRow: View {
    @ObservedObject var store: LocalModelStore
    /// Shown even before download; off, a row stays only while there is
    /// something on disk or in transit to cancel or delete.
    let offered: Bool
    /// Nil for a row that is never selected.
    let selection: (isSelected: Bool, select: () -> Void)?
    /// Nil for a row that is not a speech model.
    var languages: [LocalSpeechLanguage]? = nil
    /// The selected model's language choice; other rows list their languages.
    var language: Binding<String>? = nil
    @State private var confirmingDelete = false

    #if os(iOS)
    private static let minTarget: CGFloat = 44
    #else
    private static let minTarget: CGFloat = 24
    #endif

    private var name: String { store.displayName }

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let selection {
                        selectButton(selection)
                    } else {
                        Text(name)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                if let languages, let language {
                    Picker("Language", selection: language) {
                        ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.menu)
                } else if let languages {
                    Text(languages.count == 1 ? "Languages: \(languages[0].name)" : "\(languages.count) languages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .downloading(let progress) = store.state {
                    ProgressView(value: progress)
                        .accessibilityLabel("Downloading \(name)")
                }
                switch store.update {
                case .available?:
                    Text("An update is available. This version keeps working until the update is installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .downloading(let progress)?:
                    ProgressView(value: progress)
                        .accessibilityLabel("Updating \(name)")
                case .failed(let message)?:
                    Text("The update failed: \(message) This version still works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                case nil:
                    EmptyView()
                }
                if case .failed(let message) = store.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var isVisible: Bool {
        switch store.state {
        case .unsupported: return false
        case .notDownloaded, .failed: return offered
        case .downloading, .ready, .deleting: return true
        }
    }

    private func selectButton(_ selection: (isSelected: Bool, select: () -> Void)) -> some View {
        let isSelected = selection.isSelected
        return Button(action: selection.select) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .imageScale(.large)
                Text(name)
                    .foregroundStyle(.primary)
            }
            .frame(minHeight: Self.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var trailing: some View {
        switch store.state {
        case .unsupported:
            EmptyView()
        case .notDownloaded:
            Button("Download (\(size))") { store.download() }
                .buttonStyle(.borderless)
                .frame(minHeight: Self.minTarget)
                .contentShape(Rectangle())
                .accessibilityLabel("Download \(name), \(size)")
        case .downloading(let progress):
            HStack(spacing: 6) {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                iconButton("xmark.circle.fill", label: "Cancel downloading \(name)") {
                    store.cancelDownload()
                }
            }
        case .ready:
            HStack(spacing: 6) {
                switch store.update {
                case .available?, .failed?:
                    Button(updateTitle) { store.download() }
                        .buttonStyle(.borderless)
                        // Progress counts against the update's size, known a few seconds after launch.
                        .disabled(store.updateBytes == nil)
                        .frame(minHeight: Self.minTarget)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Update \(name)")
                case .downloading(let progress)?:
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityHidden(true)
                    iconButton("xmark.circle.fill", label: "Cancel updating \(name)") {
                        store.cancelDownload()
                    }
                case nil:
                    EmptyView()
                }
                iconButton("trash", label: "Delete \(name)") { confirmingDelete = true }
                    .confirmationDialog("Delete \(name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            Task { await store.deleteModel() }
                        }
                    }
            }
        case .deleting:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: Self.minTarget, minHeight: Self.minTarget)
                .accessibilityLabel("Deleting \(name)")
        case .failed:
            Button("Retry") { store.download() }
                .buttonStyle(.borderless)
                .frame(minHeight: Self.minTarget)
                .contentShape(Rectangle())
                .accessibilityLabel("Retry downloading \(name)")
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(minWidth: Self.minTarget, minHeight: Self.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var updateTitle: String {
        guard let bytes = store.updateBytes else { return "Update" }
        return "Update (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: store.downloadBytes, countStyle: .file)
    }
}

/// Section footer: the hardware requirement, the cloud fallback while the
/// selected model is missing, or the first-run note once it is on disk.
@MainActor
public struct LocalModelFooter: View {
    private let localEnabled: Bool
    @ObservedObject private var store: LocalModelStore

    public init(localEnabled: Bool, selection: LocalSpeechModel) {
        self.localEnabled = localEnabled
        _store = ObservedObject(wrappedValue: .store(for: selection))
    }

    public var body: some View {
        if !LocalModelSupport.isAvailable {
            Text(LocalModelSupport.requirement)
        } else if localEnabled {
            if store.state == .ready {
                Text(Self.firstRunNote)
            } else {
                Text("Cloud transcription is used until \(store.displayName) is downloaded.")
            }
        }
    }

    /// Core ML prepares a downloaded model for this device on its first load
    /// and caches the result. The system drops that cache after an OS update
    /// and when the model goes unused for a long time, so the slow load
    /// comes back then.
    static let firstRunNote = "The first dictation after a download, a system update or a long break takes longer while the model is prepared for this device."
}

/// Section footer while meetings are kept on device but a model is missing.
@MainActor
public struct LocalMeetingFooter: View {
    private let enabled: Bool
    @ObservedObject private var speech: LocalModelStore
    @ObservedObject private var diarizer: LocalModelStore = .speakerDiarizer

    /// `model` is the selected on-device model, which meetings use too.
    public init(enabled: Bool, model: LocalSpeechModel) {
        self.enabled = enabled
        _speech = ObservedObject(wrappedValue: .store(for: model))
    }

    public var body: some View {
        if LocalModelSupport.isAvailable, enabled, !LocalMeetingTranscriber.isReady {
            if LocalMeetingTranscriber.diarizes {
                Text("Meetings use cloud transcription until \(speech.displayName) and \(diarizer.displayName) are downloaded.")
            } else {
                Text("Notes use cloud transcription until \(speech.displayName) is downloaded.")
            }
        }
    }
}

/// The privacy "Meeting audio" row on both platforms. It follows the
/// on-device meeting setting and both models' download state.
@MainActor
public struct LocalMeetingPrivacyRow: View {
    private let label: String
    private let localDescription: (String) -> String
    private let cloudDescription: String
    @State private var enabled = SettingsStore().localMeetingTranscriptionEnabled
    @State private var model = SettingsStore().localSpeechModel

    /// `localDescription` receives the selected model's name.
    public init(label: String, localDescription: @escaping (String) -> String, cloudDescription: String) {
        self.label = label
        self.localDescription = localDescription
        self.cloudDescription = cloudDescription
    }

    public var body: some View {
        Content(speech: .store(for: model), enabled: enabled, label: label, localDescription: localDescription,
                cloudDescription: cloudDescription)
            .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
                switch note.object as? String {
                case "meetingSource", "modelProvider": enabled = SettingsStore().localMeetingTranscriptionEnabled
                case "localSpeechModel": model = SettingsStore().localSpeechModel
                default: break
                }
            }
    }

    private struct Content: View {
        @ObservedObject var speech: LocalModelStore
        @ObservedObject var diarizer: LocalModelStore = .speakerDiarizer
        let enabled: Bool
        let label: String
        let localDescription: (String) -> String
        let cloudDescription: String

        var body: some View {
            LabeledContent(label) {
                Text(enabled && LocalMeetingTranscriber.isReady ? localDescription(speech.displayName) : cloudDescription)
            }
        }
    }
}

/// The privacy "Audio" row on both platforms. It follows the on-device
/// setting, the selected model, and that model's download state, so it never
/// claims audio stays local while the model is missing.
@MainActor
public struct LocalAudioPrivacyRow: View {
    private let provider: String?
    private let cloudDescription: String
    @State private var localEnabled = SettingsStore().localTranscriptionEnabled
    @State private var model = SettingsStore().localSpeechModel

    /// `provider` names the cloud provider, nil when it cannot transcribe;
    /// `cloudDescription` is the row's text while on-device transcription is off.
    public init(provider: String?, cloudDescription: String) {
        self.provider = provider
        self.cloudDescription = cloudDescription
    }

    public var body: some View {
        Content(store: .store(for: model), localEnabled: localEnabled, provider: provider, cloudDescription: cloudDescription)
            .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
                switch note.object as? String {
                case "dictationSource", "modelProvider": localEnabled = SettingsStore().localTranscriptionEnabled
                case "localSpeechModel": model = SettingsStore().localSpeechModel
                default: break
                }
            }
    }

    private struct Content: View {
        @ObservedObject var store: LocalModelStore
        let localEnabled: Bool
        let provider: String?
        let cloudDescription: String

        var body: some View {
            LabeledContent("Audio") { Text(value) }
        }

        private var value: String {
            let name = store.displayName
            guard let provider else {
                guard localEnabled else { return "Not sent: Claude doesn't transcribe" }
                return store.state == .ready ? "Transcribed on device by \(name)" : "\(name) unavailable, so not sent anywhere"
            }
            guard localEnabled else { return cloudDescription }
            return store.state == .ready
                ? "Transcribed on device by \(name); sent to \(provider) only if that fails"
                : "\(name) unavailable, so sent to \(provider)"
        }
    }
}

extension View {
    /// Picking Claude, which has no speech model, warns when the on-device
    /// models that dictation and meetings then need are not downloaded.
    /// `openDictation` shows the Dictation settings, where they download.
    @MainActor public func claudeVoiceAlert(provider: ModelProvider, openDictation: @escaping () -> Void) -> some View {
        modifier(ClaudeVoiceAlert(provider: provider, openDictation: openDictation))
    }
}

@MainActor
private struct ClaudeVoiceAlert: ViewModifier {
    let provider: ModelProvider
    let openDictation: () -> Void
    @State private var missing: Missing?

    /// The models not downloaded, by name. Dictation needs only the speech
    /// model; meetings on the Mac also need the diarizer.
    private struct Missing {
        var speech: String?
        var diarizer: String?
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: provider) { _, value in
                guard !value.transcribes else { return }
                let found = Self.missingModels
                if found.speech != nil || found.diarizer != nil { missing = found }
            }
            .alert("Claude needs on-device models for voice",
                   isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })) {
                if LocalModelSupport.isAvailable {
                    Button("Open Dictation Settings", action: openDictation)
                    Button("Later", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(message)
            }
    }

    private static var missingModels: Missing {
        let speech = LocalModelStore.store(for: SettingsStore().localSpeechModel)
        let diarizer = LocalModelStore.speakerDiarizer
        return Missing(
            speech: speech.state == .ready ? nil : speech.displayName,
            diarizer: LocalMeetingTranscriber.diarizes && diarizer.state != .ready ? diarizer.displayName : nil
        )
    }

    private var message: String {
        #if os(macOS)
        let device = "this Mac", place = "Settings → Dictation"
        #else
        let device = "this iPhone", place = "Settings › Dictation"
        #endif
        guard LocalModelSupport.isAvailable else {
            return "Claude has no speech model, and \(device) can't run on-device models, so dictation and meetings won't be transcribed with Claude."
        }
        switch (missing?.speech, missing?.diarizer) {
        case let (speech?, diarizer?):
            return "Claude has no speech model, so dictation and meetings are transcribed on \(device). Download \(speech) in \(place) to dictate, and \(diarizer) as well for meetings; until then, nothing you say is transcribed with Claude."
        case let (speech?, nil):
            return "Claude has no speech model, so dictation and meetings are transcribed on \(device). Download \(speech) in \(place); until then, nothing you say is transcribed with Claude."
        case let (nil, diarizer?):
            return "Claude has no speech model, so meetings are transcribed on \(device). Dictation already works on device; download \(diarizer) in \(place) to transcribe meetings with Claude."
        case (nil, nil):
            return ""
        }
    }
}
