import SwiftUI
import VoiceIQCore

/// Play and Download for a dictation's audio (a note plays from its
/// `MeetingPlaybackBar`). Download shares the
/// `.m4a`, so Save to Files keeps it. When the audio is not on this device
/// only the reason shows, not two buttons that do nothing.
struct RecordingAudioControls: View {
    let audio: RecordedAudio
    @StateObject private var player = RecordingPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if audio.isAvailable {
                HStack(spacing: Theme.Spacing.s) {
                    Button { player.toggle(audio) } label: {
                        switch player.state {
                        case .idle: Label("Play", systemImage: "play.fill")
                        case .preparing: Label("Preparing…", systemImage: "hourglass")
                        case .playing, .paused: Label("Stop", systemImage: "stop.fill")
                        }
                    }
                    .buttonStyle(.compactSecondary)
                    ShareLink(item: audio, preview: SharePreview(audio.name)) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.compactSecondary)
                }
            } else {
                Text("The audio isn't on this \(UIDevice.current.localizedModel).")
                    .font(Theme.Fonts.footnote())
                    .foregroundStyle(Theme.Colors.muted)
            }
        }
        .onChange(of: audio.source) { _, _ in player.stop() }
        .onDisappear { player.stop() }
    }
}
