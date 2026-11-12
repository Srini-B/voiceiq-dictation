import SwiftUI
import VoiceIQBridge

/// The newest lines of `DebugLog`, and the whole log as a file to share.
struct DebugLogView: View {
    @State private var lines: [String] = []
    @State private var file: URL?

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "No entries yet. Turn on Write a debug log, then use VoiceiQ." : lines.joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.page)
        }
        .defaultScrollAnchor(.bottom)
        .themedBackground()
        .navigationTitle("Debug log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let file {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") {
                    DebugLog.clear()
                    lines = []
                    file = nil
                }
                .disabled(lines.isEmpty)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let (recent, exported) = await Task.detached(priority: .userInitiated) {
            let recent = DebugLog.recentLines(limit: 500)
            let exported = recent.isEmpty ? nil : (try? DebugLog.export())
            return (recent, exported)
        }.value
        lines = recent
        file = exported
    }
}
