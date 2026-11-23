import AppKit
import SwiftUI
import VoiceIQCore

/// The next calendar meeting, at the top of Meetings.
struct NextMeetingCard: View {
    let meeting: CalendarMeetings.Upcoming
    let now: Date
    @ObservedObject var engine: MeetingEngine

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xxs) {
            Text("Next meeting · \(CalendarMeetings.when(meeting.start, now: now))")
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(.secondary)
            Text(meeting.title).font(VoiceIQUI.TypeScale.body()).lineLimit(2)
            if let button = engine.nextMeetingButton(for: meeting) {
                Button { engine.join(meeting) } label: {
                    Label(button.title, systemImage: button.icon)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(!button.enabled)
                .padding(.top, VoiceIQUI.Spacing.xs)
                .help(meeting.join?.url.absoluteString ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiceIQUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
    }
}

/// The next meeting's button, on the card and in the menu-bar menu.
enum NextMeetingButton {
    /// Open the call and record from its first second. Shown even when call
    /// detection hears a call on the same service: it knows the service, not
    /// the meeting, so that call may be another one.
    case joinAndRecord(app: String)
    /// A recording is running.
    case inProgress

    var title: String {
        switch self {
        case let .joinAndRecord(app): return "Join \(app) and Record"
        case .inProgress: return "In Progress"
        }
    }

    var icon: String {
        switch self {
        case .joinAndRecord: return "video"
        case .inProgress: return "waveform"
        }
    }

    var enabled: Bool { if case .inProgress = self { return false }; return true }
}

extension MeetingEngine {
    /// Nil when the invite has no call link.
    func nextMeetingButton(for meeting: CalendarMeetings.Upcoming) -> NextMeetingButton? {
        guard let join = meeting.join else { return nil }
        if isRecording { return .inProgress }
        return .joinAndRecord(app: join.app)
    }

    /// Records from before the call is opened, with no call source, since a
    /// call detected now may be another one. The recording takes this
    /// meeting's title and invitees, which a lookup by the clock can miss
    /// when it is joined early.
    func join(_ meeting: CalendarMeetings.Upcoming) {
        guard !isRecording, let url = meeting.join?.url else { return }
        startRecording(event: meeting.event, joining: meeting.join)
        NSWorkspace.shared.open(url)
    }
}
