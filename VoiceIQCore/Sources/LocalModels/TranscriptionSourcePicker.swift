import SwiftUI

/// The segmented source picker shared by the macOS and iOS settings. On
/// device appears only where local models run; the provider segment follows
/// the Provider setting. Claude's segment is DeepInfra's Nemotron, so picking
/// it without a DeepInfra key adds a row saying where to add one. The caller
/// owns the selection and persists it.
@MainActor
public struct TranscriptionSourcePicker: View {
    private let label: String
    @Binding private var selection: TranscriptionSource
    @State private var provider = SettingsStore().preferredProvider
    @State private var providerTranscribes = SettingsStore().providerTranscribes

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
            guard let key = note.object as? String,
                  key == "modelProvider" || key == KeychainStore.Secret.deepInfra.settingKey else { return }
            provider = SettingsStore().preferredProvider
            providerTranscribes = SettingsStore().providerTranscribes
        }
        if selection == .provider, !providerTranscribes {
            Text("Add a DeepInfra key in \(Self.keysLocation) to use Nemotron 3.5.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    #if os(macOS)
    private static let keysLocation = "Settings → Advanced"
    #else
    private static let keysLocation = "Provider & Keys"
    #endif

    private var options: [TranscriptionSource] {
        TranscriptionSource.allCases.filter { $0 != .onDevice || LocalModelSupport.isAvailable }
    }
}
