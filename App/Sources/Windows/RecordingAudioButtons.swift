import SwiftUI
import VoiceIQCore

/// Play and Download for a dictation's or a meeting's audio, as icon buttons
/// for a detail header. Both are disabled when the audio is not on this Mac.
struct RecordingAudioButtons: View {
    let audio: RecordedAudio
    /// Where Download saved the file, or why it couldn't, for the pane's export message.
    let saved: (ExportResult) -> Void

    @StateObject private var player = RecordingPlayer()
    @State private var saving = false

    static let missing = "The audio isn't on this Mac"

    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            Button { player.toggle(audio) } label: {
                if player.state == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(player.state == .playing ? "Stop" : "Play audio",
                          systemImage: player.state == .playing ? "stop.fill" : "play.fill")
                }
            }
            .help(audio.isAvailable ? (player.state == .idle ? "Play audio" : "Stop") : Self.missing)
            Button(action: download) {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Download audio", systemImage: "arrow.down.circle")
                }
            }
            .help(audio.isAvailable ? "Save the audio to Downloads" : Self.missing)
            .disabled(saving)
        }
        .labelStyle(.iconOnly)
        .disabled(!audio.isAvailable)
        .onChange(of: audio.source) { _, _ in player.stop() }
        .onDisappear { player.stop() }
    }

    /// An `.m4a` in Downloads, numbered when the name is taken.
    private func download() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let file = try await audio.m4a()
                let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true)
                var url = downloads.appendingPathComponent(file.lastPathComponent), copy = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = downloads.appendingPathComponent("\(audio.name) \(copy).m4a"); copy += 1
                }
                try FileManager.default.copyItem(at: file, to: url)
                saved(.saved(url))
            } catch {
                saved(.failed(error.localizedDescription))
            }
        }
    }
}
