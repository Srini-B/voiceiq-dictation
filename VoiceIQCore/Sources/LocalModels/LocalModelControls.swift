import SwiftUI
import VoiceIQSpeech

/// The speech models in the shared on-device transcription group
/// (`SpeechSourceSection`). While on-device transcription is on, every model
/// has a row: the leading check selects it, and the trailing action
/// downloads, cancels, or deletes that model alone. While it is off, only
/// models on disk or in transit keep a row, so they can still be cancelled or
/// deleted.
@MainActor
public struct LocalModelControls: View {
    private let localEnabled: Bool
    @Binding private var selection: LocalSpeechModel
    /// The stored code, kept as is: the picker shows the selected model's
    /// reading of it, so switching models does not lose a choice.
    @State private var languageCode = SettingsStore().localSpeechLanguageCode

    public init(localEnabled: Bool, selection: Binding<LocalSpeechModel>) {
        self.localEnabled = localEnabled
        _selection = selection
    }

    public var body: some View {
        ForEach(LocalSpeechModel.available, id: \.self) { model in
            LocalModelRow(
                store: .store(for: model),
                offered: localEnabled,
                selection: localEnabled ? (isSelected: model == selection, select: { selection = model }) : nil,
                languages: model.languages,
                language: localEnabled && model == selection ? languageBinding(for: model) : nil
            )
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
}

/// One model's row: its name (or select button), size, and download,
/// cancel or delete action.
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
                if case .failed(let message) = store.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var isVisible: Bool { Self.isVisible(store.state, offered: offered) }

    static func isVisible(_ state: LocalModelState, offered: Bool) -> Bool {
        switch state {
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
            Text(size)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("\(size) on disk")
            iconButton("trash", label: "Delete \(name)") { confirmingDelete = true }
                .confirmationDialog("Delete \(name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        Task { await store.deleteModel() }
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

    private var size: String {
        ByteCountFormatter.string(fromByteCount: store.downloadBytes, countStyle: .file)
    }
}

/// Transcription footer: the cloud fallback while the selected model is
/// missing, or the first-run note once it is on disk.
@MainActor
public struct LocalModelFooter: View {
    private let localEnabled: Bool
    @ObservedObject private var store: LocalModelStore

    public init(localEnabled: Bool, selection: LocalSpeechModel) {
        self.localEnabled = localEnabled
        _store = ObservedObject(wrappedValue: .store(for: selection))
    }

    public var body: some View {
        if localEnabled {
            if store.state == .ready {
                Text(Self.firstRunNote)
            } else {
                Text("Gemini transcribes until \(store.displayName) is downloaded.")
            }
        }
    }

    /// Core ML prepares a downloaded model for this device on its first load
    /// and caches the result. The system drops that cache after an OS update
    /// and when the model goes unused for a long time, so the slow load
    /// comes back then.
    static let firstRunNote = "The first dictation after a download, a system update or a long break takes longer while the model is prepared for this device."
}

/// The privacy "Audio" row on both platforms. It follows the on-device
/// setting, the selected model, and that model's download state, so it never
/// claims audio stays local while the model is missing.
@MainActor
public struct LocalAudioPrivacyRow: View {
    private let provider: String
    private let cloudDescription: String
    @State private var localEnabled = SettingsStore().localTranscriptionEnabled
    @State private var model = SettingsStore().localSpeechModel

    /// `provider` names the cloud provider; `cloudDescription` is the row's
    /// text while on-device transcription is off.
    public init(provider: String, cloudDescription: String) {
        self.provider = provider
        self.cloudDescription = cloudDescription
    }

    public var body: some View {
        Content(store: .store(for: model), localEnabled: localEnabled, provider: provider, cloudDescription: cloudDescription)
            .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
                switch note.object as? String {
                case "transcriptionSource": localEnabled = SettingsStore().localTranscriptionEnabled
                case "onDeviceSpeechModel": model = SettingsStore().localSpeechModel
                default: break
                }
            }
    }

    private struct Content: View {
        @ObservedObject var store: LocalModelStore
        let localEnabled: Bool
        let provider: String
        let cloudDescription: String

        var body: some View {
            LabeledContent("Audio") { Text(value) }
        }

        private var value: String {
            let name = store.displayName
            guard localEnabled else { return cloudDescription }
            return store.state == .ready
                ? "Transcribed on device by \(name); sent to \(provider) only if that fails"
                : "\(name) unavailable, so sent to \(provider)"
        }
    }
}
