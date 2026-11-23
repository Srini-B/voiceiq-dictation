import SwiftUI
import VoiceIQCore

/// The next calendar meeting, at the top of Notes. Shows nothing until the
/// calendar is connected or when no meeting is coming up in the next week.
struct NextMeetingSection: View {
    @StateObject private var model = NextMeetingModel()

    var body: some View {
        if let next = model.next {
            Section("Next meeting") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(CalendarMeetings.when(next.start, now: model.now))
                        .font(Theme.Fonts.caption())
                        .foregroundStyle(Theme.Colors.muted)
                    Text(next.title).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                }
                .padding(.vertical, Theme.Spacing.xs)
                if let join = next.join {
                    Link(destination: join.url) {
                        Label("Join \(join.app)", systemImage: "video")
                            .font(Theme.Fonts.label())
                            .frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
    }
}
