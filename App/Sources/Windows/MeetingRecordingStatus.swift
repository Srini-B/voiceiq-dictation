import SwiftUI
import VoiceIQCore

/// What the notes pane shows while its meeting records: a red mark with the
/// running time, a live level for each side of the call, and Discard.
struct MeetingRecordingStatus: View {
    @ObservedObject var engine: MeetingEngine
    let since: Date
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.m) {
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
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let levels = engine.liveLevels ?? (0, 0)
                VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
                    meter(engine.micMuted ? "You (muted)" : "You", level: engine.micMuted ? 0 : levels.mic)
                    meter("Call", level: levels.call)
                }
            }
        }
        .padding(VoiceIQUI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.gRed.opacity(0.08)))
    }

    /// RMS on a −60…0 dB scale, so speech fills most of the bar and a quiet room little of it.
    private func meter(_ label: String, level: Float) -> some View {
        let db = 20 * log10(max(level, 0.000_001))
        let fill = CGFloat(min(max((db + 60) / 60, 0), 1))
        return HStack(spacing: VoiceIQUI.Spacing.s) {
            Text(label).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(VoiceIQUI.Colors.gGreen).frame(width: geometry.size.width * fill)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(fill > 0.3 ? "Hearing sound" : "Quiet")
    }

    /// "0:07", "12:40", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
