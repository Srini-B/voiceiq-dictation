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
                // Detection knows the service, not the meeting: the call it
                // hears may be an earlier one, so this one can still be opened.
                if case .record = button, let join = meeting.join {
                    Link("Open \(join.app) Link", destination: join.url)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiceIQUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
    }
}

/// The next meeting's button, on the card and in the menu-bar menu.
enum NextMeetingButton {
    /// The call is not on yet: open it and record from its first second.
    case joinAndRecord(app: String)
    /// Call detection hears this meeting's service: the user has joined.
    case record
    /// A recording is running.
    case inProgress

    var title: String {
        switch self {
        case let .joinAndRecord(app): return "Join \(app) and Record"
        case .record: return "Record"
        case .inProgress: return "In Progress"
        }
    }

    var icon: String {
        switch self {
        case .joinAndRecord: return "video"
        case .record: return "record.circle"
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
        if joinedCall(meeting) != nil { return .record }
        return .joinAndRecord(app: join.app)
    }

    /// The call detection hears, when it is this meeting's service and the
    /// meeting is due: from 10 minutes before its start, the window in which a
    /// recording takes an event's title. Earlier, a call on the same service is
    /// another meeting.
    private func joinedCall(_ meeting: CalendarMeetings.Upcoming) -> CallSource? {
        guard let call = detectedSource, meeting.join?.matches(call) == true,
              meeting.start.timeIntervalSinceNow <= CalendarMeetings.earlyStart else { return nil }
        return call
    }

    /// Joined already: records that call, following its audio and its end
    /// like an accepted call offer. Not yet: records from before the call is
    /// opened, with no call source, since a call detected now is not this
    /// one. Either way the recording takes this meeting's title and invitees,
    /// which a lookup by the clock can miss when it is joined early.
    func join(_ meeting: CalendarMeetings.Upcoming) {
        guard !isRecording, let url = meeting.join?.url else { return }
        if let call = joinedCall(meeting) {
            startRecording(source: call, event: meeting.event)
        } else {
            startRecording(event: meeting.event)
            NSWorkspace.shared.open(url)
        }
    }
}
