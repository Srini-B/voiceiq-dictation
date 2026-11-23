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
            if let join = meeting.join {
                Button { engine.join(meeting) } label: {
                    Label("Join \(join.app) and Record", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .padding(.top, VoiceIQUI.Spacing.xs)
                .help(join.url.absoluteString)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiceIQUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
    }
}

extension MeetingEngine {
    /// Records the call from before it is joined, then opens it. Already
    /// recording: only opens it. No call source: a call detected now is not
    /// this one, and following its processes would miss the joined call's
    /// audio and stop when that other call ends. The recording takes this
    /// meeting's title and invitees, which a lookup by the clock can miss
    /// when it is joined early.
    func join(_ meeting: CalendarMeetings.Upcoming) {
        guard let url = meeting.join?.url else { return }
        if !isRecording { startRecording(event: meeting.event) }
        NSWorkspace.shared.open(url)
    }
}
