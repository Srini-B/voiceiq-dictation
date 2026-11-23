import SwiftUI
import VoiceIQCore

/// The next calendar meeting, at the top of Meetings. Shows nothing until the
/// calendar is connected or when no meeting is coming up in the next week.
struct NextMeetingCard: View {
    @StateObject private var model = NextMeetingModel()

    var body: some View {
        if let next = model.next {
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xxs) {
                Text("Next meeting · \(CalendarMeetings.when(next.start, now: model.now))")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
                Text(next.title).font(VoiceIQUI.TypeScale.body()).lineLimit(2)
                if let join = next.join {
                    Link(destination: join.url) {
                        Label("Join \(join.app)", systemImage: "video")
                            .font(VoiceIQUI.TypeScale.label())
                    }
                    .padding(.top, VoiceIQUI.Spacing.xxs)
                    .help(join.url.absoluteString)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoiceIQUI.Spacing.s)
            .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
            .padding(.horizontal, VoiceIQUI.Spacing.s)
            .padding(.top, VoiceIQUI.Spacing.l)
        }
    }
}
