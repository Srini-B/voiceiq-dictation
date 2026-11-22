import SwiftUI
import VoiceIQCore

/// "Meeting detected" offer. Nothing records until Start is pressed.
struct MeetingPromptContent: View {
    let name: String

    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(VoiceIQUI.Colors.primary)
            Text("Meeting in \(name) — record it?")
                .font(VoiceIQUI.TypeScale.label())
                .foregroundStyle(VoiceIQUI.Colors.onSurface)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Button("Start") {
                NotificationCenter.default.post(name: .pillMeetingAccepted, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(VoiceIQUI.Colors.primary)
            .accessibilityLabel("Start recording the meeting")
            Button {
                NotificationCenter.default.post(name: .pillMeetingDismissed, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not this time")
        }
    }
}

/// The recorded call ended: a countdown to stopping, with Stop now and Keep
/// recording. FluidVoice asks the same way (altic-dev/FluidVoice).
struct MeetingEndingContent: View {
    let until: Date

    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VoiceIQUI.Colors.error)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Meeting ended · Stopping in \(max(0, Int(until.timeIntervalSince(context.date).rounded(.up))))s")
                    .font(VoiceIQUI.TypeScale.label())
                    .foregroundStyle(VoiceIQUI.Colors.onSurface)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Button("Stop now") {
                NotificationCenter.default.post(name: .pillMeetingStopTapped, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(VoiceIQUI.Colors.primary)
            .accessibilityLabel("Stop recording now and make meeting notes")
            Button("Keep recording") {
                NotificationCenter.default.post(name: .pillMeetingKeepTapped, object: nil)
            }
            .controlSize(.small)
        }
    }
}

/// Recording: elapsed time, working bars, and Stop.
/// The timer is a `TimelineView` over the start date, so no published tick is needed.
struct MeetingRecordingContent: View {
    let since: Date

    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            Image(systemName: "record.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VoiceIQUI.Colors.error)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(since)))
                    .font(VoiceIQUI.TypeScale.numeric())
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
            }
            WaveformView(processing: true)
            Text("Recording meeting")
                .font(VoiceIQUI.TypeScale.label())
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NotificationCenter.default.post(name: .pillMeetingStopTapped, object: nil)
            } label: {
                ZStack {
                    Circle().fill(VoiceIQUI.Colors.primary)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(VoiceIQUI.Colors.onPrimary)
                        .frame(width: 10, height: 10)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording and make meeting notes")
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
