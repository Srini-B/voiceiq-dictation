import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceIQBridge
import VoiceIQCore

/// Settings › Advanced: the switch for `DebugLog`, and the file to send support.
struct DebugLogSection: View {
    @State private var enabled = DebugLog.isEnabled
    @State private var bytes = 0
    @State private var feedback: String?

    var body: some View {
        Section {
            Toggle("Write a debug log", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    DebugLog.setEnabled(on)
                    refresh()
                }
            LabeledContent("Saved") {
                Text(bytes == 0 ? "Nothing yet" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            if let feedback {
                Text(feedback).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
            }
            HStack {
                Button("Export…") { export() }
                Button("Show in Finder") { reveal() }
                Button("Clear") {
                    DebugLog.clear()
                    feedback = "Debug log cleared"
                    refresh()
                }
                Spacer()
            }
            .disabled(bytes == 0)
        } header: {
            Text("Debug log")
        } footer: {
            Text("While this is on, VoiceiQ writes down everything it does: dictation, transcription with each provider, meetings, the Chrome extension, settings changes, sync, network requests and errors. Export the file and send it with a bug report. API keys and tokens are removed, and transcripts, window titles and page addresses are never written. VoiceiQ keeps the last \(DebugLog.keepDays) days, up to \(DebugLog.maxTotalBytes / 1_000_000) MB, and deletes older entries on its own.")
        }
        .onAppear { refresh() }
        // The log grows while the pane is open; Export and Clear follow it.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        bytes = DebugLog.totalBytes
    }

    private func export() {
        do {
            let file = try DebugLog.export()
            defer { DebugLog.discardExport(file) }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.lastPathComponent
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: file, to: url)
            feedback = "Exported \(url.lastPathComponent)"
        } catch {
            Log.ui.error("debug log export failed: \(error)")
            feedback = "Export failed: \(error.localizedDescription)"
        }
    }

    private func reveal() {
        guard let folder = DebugLog.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
