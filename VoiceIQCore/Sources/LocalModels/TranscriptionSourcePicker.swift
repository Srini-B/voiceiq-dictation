import SwiftUI

/// The segmented source picker shared by the macOS and iOS settings. On
/// device appears only where local models run; ElevenLabs appears while its
/// key is stored or while it is the selection, so a removed key never leaves
/// a picker with no selected segment; the provider segment follows the
/// Provider setting. The caller owns the selection and persists it.
@MainActor
public struct TranscriptionSourcePicker: View {
    private let label: String
    @Binding private var selection: TranscriptionSource
    @State private var provider = SettingsStore().preferredProvider
    @State private var hasElevenLabsKey = KeychainStore.loadElevenLabsKey() != nil

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
            switch note.object as? String {
            case "modelProvider": provider = SettingsStore().preferredProvider
            case KeychainStore.Secret.elevenLabs.settingKey: hasElevenLabsKey = KeychainStore.loadElevenLabsKey() != nil
            default: break
            }
        }
    }

    private var options: [TranscriptionSource] {
        TranscriptionSource.allCases.filter { source in
            switch source {
            case .onDevice: return LocalModelSupport.isAvailable
            case .elevenLabs: return hasElevenLabsKey || selection == .elevenLabs
            case .provider: return true
            }
        }
    }
}
