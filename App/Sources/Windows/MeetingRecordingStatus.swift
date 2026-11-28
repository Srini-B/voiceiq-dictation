import SwiftUI
import VoiceIQCore

/// What the notes pane shows while its meeting records: a red mark with the
/// running time, Discard, and the live waveform of both sides of the call.
struct MeetingRecordingStatus: View {
    @ObservedObject var engine: MeetingEngine
    let since: Date
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.s) {
            HStack(spacing: VoiceIQUI.Spacing.s) {
                Circle().fill(VoiceIQUI.Colors.gRed).frame(width: 10, height: 10)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Recording  \(Self.clock(context.date.timeIntervalSince(since)))")
                        .font(VoiceIQUI.TypeScale.body().monospacedDigit())
                }
                Spacer(minLength: VoiceIQUI.Spacing.s)
                Button("Discard…", role: .destructive, action: discard)
                    .help("Delete this recording without making notes")
            }
            LiveMeetingWaveform(engine: engine, style: .voiceIQ, hearsCall: true)
        }
        .padding(VoiceIQUI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.gRed.opacity(0.08)))
    }

    /// "0:07", "12:40", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String { MeetingPlaybackBar.clock(seconds) }
}

extension WaveformStyle {
    /// The Mac's meeting waveforms: ink for you, grey for the call, red only for now.
    static let voiceIQ = WaveformStyle(you: VoiceIQUI.Colors.onSurface,
                                       call: VoiceIQUI.Colors.outline,
                                       fill: VoiceIQUI.Colors.surfaceContainer,
                                       accent: VoiceIQUI.Colors.gRed,
                                       label: VoiceIQUI.TypeScale.labelSmall(),
                                       time: VoiceIQUI.TypeScale.numeric())
}
