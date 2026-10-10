#if os(macOS)
import SwiftUI
import VoiceIQSpeech

/// The model list in macOS settings. While on-device
/// transcription is on, every model has a row: the leading check selects it,
/// and the trailing action downloads, cancels, or deletes that model alone.
/// While it is off, only models on disk or in transit keep a row, so they can
/// still be cancelled or deleted. The English tools pack follows the same
/// rules but is never selected.
@MainActor
public struct LocalModelControls: View {
    private let localEnabled: Bool
    @Binding private var selection: LocalSpeechModel

    public init(localEnabled: Bool, selection: Binding<LocalSpeechModel>) {
        self.localEnabled = localEnabled
        _selection = selection
    }

    public var body: some View {
        if LocalModelSupport.isAvailable {
            ForEach(LocalSpeechModel.allCases, id: \.self) { model in
                LocalModelRow(
                    store: .store(for: model),
                    localEnabled: localEnabled,
                    selection: (isSelected: model == selection, select: { selection = model })
                )
            }
            LocalModelRow(store: .englishTools, localEnabled: localEnabled, selection: nil)
            if localEnabled {
                Text(Self.englishNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static let englishNote = "On-device dictation is English only. English tools add speech detection and Parakeet dictionary correction. Without them, on-device transcription still works."

    /// Shown beneath the real-time toggle while on-device transcription is on
    /// and Nemotron is not downloaded.
    public static let streamingHint = "Nemotron 3.5 is optimized for streaming. Download it to transcribe on device while you speak."
}

@MainActor
private struct LocalModelRow: View {
    @ObservedObject var store: LocalModelStore
    let localEnabled: Bool
    /// Nil for a row that is never selected.
    let selection: (isSelected: Bool, select: () -> Void)?
    @State private var confirmingDelete = false

    private static let minTarget: CGFloat = 24

    private var name: String { store.displayName }

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if localEnabled, let selection {
                        selectButton(selection)
                    } else {
                        Text(name)
                    }
                    Spacer(minLength: 8)
                    trailing
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

    /// Off, a row stays only while there is something on disk or in transit
    /// to cancel or delete.
    private var isVisible: Bool {
        switch store.state {
        case .unsupported: return false
        case .notDownloaded, .failed: return localEnabled
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

/// Section footer: the hardware requirement, or the cloud fallback while the
/// selected model is missing.
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
        } else if localEnabled && store.state != .ready {
            Text("Cloud transcription is used until \(store.displayName) is downloaded.")
        }
    }
}

/// The macOS privacy "Audio" row. It follows the on-device
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
                case "localTranscriptionEnabled": localEnabled = SettingsStore().localTranscriptionEnabled
                case "localSpeechModel": model = SettingsStore().localSpeechModel
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
#endif
