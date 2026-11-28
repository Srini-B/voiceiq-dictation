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
            .fixedSize()
            .layoutPriority(1)
            .accessibilityLabel("Stop recording now and make meeting notes")
            // Never squeezed or cut beside Stop now.
            Button("Keep recording") {
                NotificationCenter.default.post(name: .pillMeetingKeepTapped, object: nil)
            }
            .controlSize(.small)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
        }
    }
}

/// Recording: elapsed time, working bars, Discard and Stop.
/// The timer is a `TimelineView` over the start date, so no published tick is needed.
/// Discard asks first, in the pill; moving the pointer off the pill answers Keep.
struct MeetingRecordingContent: View {
    let since: Date
    /// Mute my mic in the Meetings window: only the far side is recorded.
    let micMuted: Bool
    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            if confirmingDiscard { discardQuestion } else { recording }
        }
        .onHover { inside in if !inside { confirmingDiscard = false } }
    }

    @ViewBuilder
    private var recording: some View {
        Image(systemName: "record.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(VoiceIQUI.Colors.error)
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.clock(context.date.timeIntervalSince(since)))
                .font(VoiceIQUI.TypeScale.numeric())
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
        }
        WaveformView(processing: true)
        Group {
            if micMuted {
                Label("Mic muted", systemImage: "mic.slash.fill")
            } else {
                Text("Recording meeting")
            }
        }
        .font(VoiceIQUI.TypeScale.label())
        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        Button {
            confirmingDiscard = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Discard this recording")
        .accessibilityLabel("Discard this recording")
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

    @ViewBuilder
    private var discardQuestion: some View {
        Text("Discard this recording?")
            .font(VoiceIQUI.TypeScale.label())
            .foregroundStyle(VoiceIQUI.Colors.onSurface)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Discard this recording? Its audio is deleted and no notes are made.")
        Button("Keep") { confirmingDiscard = false }
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Keep recording")
        Button("Discard") {
            confirmingDiscard = false
            NotificationCenter.default.post(name: .pillMeetingDiscardTapped, object: nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(VoiceIQUI.Colors.error)
        .fixedSize()
        .accessibilityLabel("Discard the recording without notes")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
