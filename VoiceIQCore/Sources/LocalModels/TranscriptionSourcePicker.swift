import SwiftUI

/// The segmented source picker shared by the macOS and iOS settings. On
/// device appears only where local models run; the provider segment follows
/// the Provider setting. Claude has no speech model, so with it dictation and
/// meetings offer only On device. The caller owns the selection and persists
/// it.
@MainActor
public struct TranscriptionSourcePicker: View {
    private let label: String
    @Binding private var selection: TranscriptionSource
    @State private var provider = SettingsStore().preferredProvider

    public init(_ label: String, selection: Binding<TranscriptionSource>) {
        self.label = label
        self._selection = selection
    }

    public var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { source in
                Text(source.displayName(for: provider)).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            guard note.object as? String == "modelProvider" else { return }
            provider = SettingsStore().preferredProvider
        }
        if selection == .provider, !provider.transcribes {
            Text("Claude doesn't transcribe. Pick Gemini or OpenAI to transcribe in the cloud.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var options: [TranscriptionSource] {
        TranscriptionSource.allCases.filter { source in
            switch source {
            case .onDevice: return LocalModelSupport.isAvailable
            case .provider: return provider.transcribes || !LocalModelSupport.isAvailable
            }
        }
    }
}
