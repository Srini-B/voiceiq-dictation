import SwiftUI
import VoiceIQBridge

/// The newest lines of `DebugLog`, and the whole log as a file to share.
struct DebugLogView: View {
    @State private var lines: [String] = []
    @State private var file: URL?
    /// Bumped by Clear and by leaving, so a load that ends later is dropped.
    @State private var generation = 0

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
                    discardExport()
                }
                .disabled(lines.isEmpty)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onDisappear { discardExport() }
    }

    /// The exported copy holds the whole log, so it goes as soon as it is replaced or unused.
    private func discardExport() {
        generation += 1
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    private func load() async {
        let started = generation
        let (recent, exported) = await Task.detached(priority: .userInitiated) {
            let recent = DebugLog.recentLines(limit: 500)
            let exported = recent.isEmpty ? nil : (try? DebugLog.export())
            return (recent, exported)
        }.value
        guard generation == started else {
            if let exported, exported != file { try? FileManager.default.removeItem(at: exported) }
            return
        }
        lines = recent
        // An export in the same second reuses the name; that file is the new one.
        if let file, file != exported { try? FileManager.default.removeItem(at: file) }
        file = exported
    }
}
