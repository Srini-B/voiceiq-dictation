import VoiceIQCore
import SwiftUI

/// The notes: title, when and who, summary, the meeting type's sections, decisions, action
/// items, notes, then the questions asked about the meeting and their answers.
struct MeetingNotesColumn<Live: View>: View {
    let meeting: MeetingMeta
    let notes: MeetingNotes?
    let transcript: [TranscriptSegment]
    /// What the meeting is doing in the background, in words; nil when idle.
    let step: String?
    /// Nil until the meeting has a transcript to ask about.
    let chat: MeetingChatModel?
    /// Shown in place of the step while the meeting records; nil otherwise.
    let live: Live?

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
                Text(meeting.displayTitle(notes: notes) ?? "Meeting").font(VoiceIQUI.TypeScale.headline())
                Text(meeting.whenText).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                if !speakers.isEmpty { people }
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
            } else if let live {
                live
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


    /// The note owner first, then the others; an import without speaker labels has none.
    private var speakers: [String] {
        let others = MeetingSpeaker.others(in: transcript).filter { $0 != GranolaImport.unlabeledSpeaker }
        return (transcript.contains { $0.speaker == MeetingSpeaker.you } ? [MeetingSpeaker.you] : []) + others
    }

    /// Everyone heard, each in their transcript colour, the note owner first.
    private var people: some View {
        let others = MeetingSpeaker.others(in: transcript)
        let names = speakers.map { meeting.displayName($0, notes: notes) }
        // A non-breaking space keeps each dot with its name when the line wraps.
        return zip(speakers, names).enumerated().reduce(Text("")) { line, entry in
            let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 7))
                .foregroundColor(Color(nsColor: SpeakerPalette.color(entry.element.0, order: others)))
            return line + Text(entry.offset == 0 ? "" : "     ") + dot + Text("\u{00A0}" + entry.element.1)
        }
        .font(VoiceIQUI.TypeScale.labelSmall())
        .foregroundStyle(.secondary)
        .accessibilityLabel("With " + names.joined(separator: ", "))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
            Text(title).font(GTFont.flex(VQ.TypeScale.title2.size, weight: VQ.TypeScale.title2.weight))
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
