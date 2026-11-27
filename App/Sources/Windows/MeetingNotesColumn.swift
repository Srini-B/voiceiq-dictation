import VoiceIQCore
import SwiftUI

/// The notes: title, when and who, summary, the meeting type's sections, decisions, action
/// items, notes, then the questions asked about the meeting and their answers.
struct MeetingNotesColumn: View {
    let meeting: MeetingMeta
    let notes: MeetingNotes?
    let transcript: [TranscriptSegment]
    /// What the meeting is doing in the background, in words; nil when idle.
    let step: String?
    /// Nil until the meeting has a transcript to ask about.
    let chat: MeetingChatModel?

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView { content(scroller) }
        }
    }

    private func content(_ scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.l) {
            if let kind = notes?.type.flatMap(MeetingKind.init(rawValue:)), kind != .general {
                Text(kind.displayName).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                    .padding(.bottom, -VoiceIQUI.Spacing.s)
            }
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
                Text(meeting.shownTitle(notes: notes) ?? "Meeting").font(GTFont.flex(22, weight: 600))
                Text(when).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                if !transcript.isEmpty { people }
            }
            if let notes {
                section("Summary") { Text(notes.summary) }
                ForEach(Array((notes.sections ?? []).enumerated()), id: \.offset) { _, part in
                    bullets(part.title, part.items)
                }
                bullets("Decisions", notes.decisions)
                if !notes.actions.isEmpty {
                    section("Action items") {
                        ForEach(Array(notes.actions.enumerated()), id: \.offset) { _, item in action(item) }
                    }
                }
                bullets("Notes", notes.notes)
            } else if let step {
                HStack(spacing: VoiceIQUI.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary)
                }
            }
            if let chat { MeetingChatTurns(chat: chat, scroller: scroller) }
        }
        .font(VoiceIQUI.TypeScale.body())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoiceIQUI.Spacing.xxl)
        .padding(.vertical, VoiceIQUI.Spacing.xl)
    }

    /// "Thu, Nov 26 · 11:50 PM · 17 min"; an import has no length.
    private var when: String {
        let day = meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let time = meeting.startedAt.formatted(date: .omitted, time: .shortened)
        guard meeting.importedFrom == nil, meeting.durationSeconds >= 1 else { return "\(day) · \(time)" }
        let minutes = Int((meeting.durationSeconds / 60).rounded())
        return "\(day) · \(time) · " + (minutes < 1 ? "\(Int(meeting.durationSeconds)) s" : "\(minutes) min")
    }

    /// Everyone heard, each in their transcript colour, the note owner first.
    private var people: some View {
        let others = MeetingSpeaker.others(in: transcript)
        let speakers = (transcript.contains { $0.speaker == MeetingSpeaker.you } ? [MeetingSpeaker.you] : []) + others
        return speakers.enumerated().reduce(Text("")) { line, entry in
            let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 7))
                .foregroundColor(Color(nsColor: SpeakerPalette.color(entry.element, order: others)))
            return line + (entry.offset == 0 ? Text("") : Text("     ")) + dot + Text(" " + meeting.displayName(entry.element, notes: notes))
        }
        .font(VoiceIQUI.TypeScale.labelSmall())
        .foregroundStyle(.secondary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
            Text(title).font(GTFont.flex(15, weight: 600))
            content()
        }
    }

    @ViewBuilder
    private func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: VoiceIQUI.Spacing.xs) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item)
                    }
                }
            }
        }
    }

    private func action(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceIQUI.Spacing.xs) {
            Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(.secondary)
            (Text(item.owner.map { "\($0): " } ?? "") + Text(item.text)
                + Text(item.deadline.map { "  \($0)" } ?? "").foregroundColor(.secondary))
        }
        .padding(.leading, VoiceIQUI.Spacing.xxs)
    }
}
