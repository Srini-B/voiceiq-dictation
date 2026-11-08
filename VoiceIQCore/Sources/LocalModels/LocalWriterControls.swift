import SwiftUI
import VoiceIQSpeech

/// Who writes dictation by the writing rules, shared by the macOS and iOS
/// settings: the provider's writing model or VoiceIQ Writer on this device.
/// The caller owns the selection and persists it.
@MainActor
public struct WritingSourcePicker: View {
    @Binding private var selection: TranscriptionSource
    @State private var provider = SettingsStore().preferredProvider

    public init(selection: Binding<TranscriptionSource>) {
        _selection = selection
    }

    public var body: some View {
        if LocalModelSupport.isAvailable, !LocalWriterModel.available.isEmpty {
            Picker("Writing", selection: $selection) {
                Text(provider.displayName).tag(TranscriptionSource.provider)
                Text("On device").tag(TranscriptionSource.onDevice)
            }
            .pickerStyle(.segmented)
            .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
                guard note.object as? String == "modelProvider" else { return }
                provider = SettingsStore().preferredProvider
            }
        }
    }
}

/// VoiceIQ Writer's rows, with the same download, update and delete actions
/// as the speech models. While on-device writing is on, every size has a row;
/// while it is off, only sizes on disk or in transit keep one. Where more
/// than one size is offered (iPhone and iPad), a downloaded size can be
/// selected.
@MainActor
public struct LocalWriterControls: View {
    private let enabled: Bool
    @Binding private var selection: LocalWriterModel

    public init(enabled: Bool, selection: Binding<LocalWriterModel>) {
        self.enabled = enabled
        _selection = selection
    }

    public var body: some View {
        if LocalModelSupport.isAvailable {
            ForEach(LocalWriterModel.available, id: \.self) { model in
                Row(store: .store(for: model), offered: enabled, selectable: LocalWriterModel.available.count > 1,
                    isSelected: model == selection, select: { selection = model })
            }
        }
    }

    private struct Row: View {
        @ObservedObject var store: LocalModelStore
        let offered: Bool
        let selectable: Bool
        let isSelected: Bool
        let select: () -> Void

        var body: some View {
            LocalModelRow(store: store, offered: offered,
                          selection: offered && selectable && store.state == .ready ? (isSelected, select) : nil)
        }
    }
}

/// Section footer while on-device writing is on: the provider writes until
/// the selected size is downloaded, and the model knows only the default
/// rules.
@MainActor
public struct LocalWriterFooter: View {
    private let enabled: Bool
    @ObservedObject private var store: LocalModelStore
    @State private var provider = SettingsStore().preferredProvider

    public init(enabled: Bool, selection: LocalWriterModel) {
        self.enabled = enabled
        _store = ObservedObject(wrappedValue: .store(for: selection))
    }

    public var body: some View {
        Group {
            if LocalModelSupport.isAvailable, enabled {
                if store.state == .ready {
                    Text("VoiceIQ Writer follows the default writing rules. Custom rules and spelling apply when \(provider.displayName) writes.")
                } else {
                    Text("\(provider.displayName) writes until \(store.displayName) is downloaded.")
                }
            }
        }
        .onAppear { provider = SettingsStore().preferredProvider }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            guard note.object as? String == "modelProvider" else { return }
            provider = SettingsStore().preferredProvider
        }
    }
}
