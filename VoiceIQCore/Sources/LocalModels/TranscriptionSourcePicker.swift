import SwiftUI

/// The segmented source picker shared by the macOS and iOS settings. On
/// device appears only where local models run. The caller owns the selection
/// and persists it.
@MainActor
public struct TranscriptionSourcePicker: View {
    private let label: String
    @Binding private var selection: TranscriptionSource

    public init(_ label: String, selection: Binding<TranscriptionSource>) {
        self.label = label
        self._selection = selection
    }

    public var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { source in
                Text(source.displayName).tag(source)
            }
        }
        .sourcePickerStyle()
    }

    private var options: [TranscriptionSource] {
        TranscriptionSource.allCases.filter { $0 == .assemblyAI || LocalModelSupport.isAvailable }
    }
}

extension View {
    /// Segmented on the Mac, where the label shows beside it. iOS drops a
    /// segmented picker's label, so there it is a menu row that names itself.
    func sourcePickerStyle() -> some View {
        #if os(iOS)
        pickerStyle(.menu)
        #else
        pickerStyle(.segmented)
        #endif
    }
}
