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
            PillChip(title: "Start", role: .primary) {
                NotificationCenter.default.post(name: .pillMeetingAccepted, object: nil)
            }
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
            PillChip(title: "Stop now", role: .destructive) {
                NotificationCenter.default.post(name: .pillMeetingStopTapped, object: nil)
            }
            .layoutPriority(1)
            .accessibilityLabel("Stop recording now and make meeting notes")
            // Never squeezed or cut beside Stop now.
            PillChip(title: "Keep recording", role: .neutral) {
                NotificationCenter.default.post(name: .pillMeetingKeepTapped, object: nil)
            }
            .layoutPriority(1)
        }
    }
}

/// A stopped meeting's notes are being made in the background. The success
/// check replaces it when they are saved; before this nothing showed between
/// Stop and the check with the Meetings window closed (Fable, M6).
struct MeetingNotesContent: View {
    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            WaveformView(processing: true, tint: VoiceIQUI.Colors.gGreen)
            Text("Making notes…")
                .font(VoiceIQUI.TypeScale.label())
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.trailing, VoiceIQUI.Spacing.xs)
    }
}

/// A button the pill draws itself. The pill's panel never becomes key, so
/// macOS draws system bordered buttons in their inactive grey there, and a
/// red Discard looked the same as Keep (Fable, M6).
struct PillChip: View {
    enum Role { case primary, destructive, neutral }
    let title: String
    let role: Role
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(VoiceIQUI.TypeScale.label())
                .foregroundStyle(role == .neutral ? VoiceIQUI.Colors.onSurface : Color.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, VoiceIQUI.Spacing.s)
                .frame(height: 26)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var fill: Color {
        switch role {
        case .primary: return VoiceIQUI.Colors.primaryFill
        case .destructive: return VoiceIQUI.Colors.errorFill
        case .neutral: return VoiceIQUI.Colors.onSurfaceVariant.opacity(0.16)
        }
    }
}

/// Recording: elapsed time, working bars, mute, Discard and Stop.
/// The timer is a `TimelineView` over the start date, so no published tick is needed.
/// Discard asks first, in the pill; moving the pointer off the pill answers Keep.
/// The question is laid over the recording row, which keeps its width: the
/// pill hugs its content, and a narrower question shrank it out from under
/// the pointer, which read as leaving and answered Keep (Neon on #143).
struct MeetingRecordingContent: View {
    let since: Date
    /// Mute my mic in the Meetings window: only the far side is recorded.
    let micMuted: Bool
    @State private var confirmingDiscard = false

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: VoiceIQUI.Spacing.s) { recording }
                .opacity(confirmingDiscard ? 0 : 1)
                .allowsHitTesting(!confirmingDiscard)
                .accessibilityHidden(confirmingDiscard)
            if confirmingDiscard {
                HStack(spacing: VoiceIQUI.Spacing.s) { discardQuestion }
            }
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
        // One colour, the window meter's green: red bars beside the record mark read as a warning (Fable, M6).
        WaveformView(processing: true, tint: VoiceIQUI.Colors.gGreen)
        // The longer label always holds its place, so muting doesn't move the buttons.
        ZStack(alignment: .leading) {
            Text("Recording meeting").opacity(micMuted ? 0 : 1).accessibilityHidden(micMuted)
            if micMuted { Text("Mic muted") }
        }
        .font(VoiceIQUI.TypeScale.label())
        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        Button {
            NotificationCenter.default.post(name: .pillMeetingMuteTapped, object: nil)
        } label: {
            Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(micMuted ? VoiceIQUI.Colors.error : VoiceIQUI.Colors.onSurfaceVariant)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(micMuted ? "Record your voice again" : "Stop recording your voice; the other side keeps recording")
        .accessibilityLabel(micMuted ? "Unmute my mic" : "Mute my mic")
        // A trash can, not ×: × reads as closing the pill (Fable, M6).
        Button {
            confirmingDiscard = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Discard this recording")
        .accessibilityLabel("Discard this recording")
        Button {
            NotificationCenter.default.post(name: .pillMeetingStopTapped, object: nil)
        } label: {
            ZStack {
                // Red, as the Meetings window's Stop recording (Fable, M6).
                Circle().fill(VoiceIQUI.Colors.gRed)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help("Stop recording and make notes")
        .accessibilityLabel("Stop recording and make meeting notes")
    }

    @ViewBuilder
    private var discardQuestion: some View {
        Text("Discard this recording?")
            .font(VoiceIQUI.TypeScale.label())
            .foregroundStyle(VoiceIQUI.Colors.onSurface)
            .lineLimit(1)
            // Sized to the text: the pill has no fixed width, so a flexible frame would stretch it to 560 pt (Neon on #137).
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Discard this recording? Its audio is deleted and no notes are made.")
        PillChip(title: "Discard", role: .destructive) {
            confirmingDiscard = false
            NotificationCenter.default.post(name: .pillMeetingDiscardTapped, object: nil)
        }
        .accessibilityLabel("Discard the recording without notes")
        // Keep last, where the trash can was: a double click on the trash keeps.
        PillChip(title: "Keep", role: .neutral) { confirmingDiscard = false }
            .accessibilityLabel("Keep recording")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
