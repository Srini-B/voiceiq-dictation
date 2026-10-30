import VoiceIQCore
import SwiftUI

/// The notes: title, summary, the meeting type's sections, decisions, action items, notes.
struct MeetingNotesColumn: View {
    let meeting: MeetingMeta
    let notes: MeetingNotes?
    /// What the meeting is doing in the background, in words; nil when idle.
    let step: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.l) {
                if let kind = notes?.type.flatMap(MeetingKind.init(rawValue:)), kind != .general {
                    Text(kind.displayName).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
                        .padding(.bottom, -VoiceIQUI.Spacing.s)
                }
                Text(notes?.title ?? meeting.title ?? "Meeting").font(GTFont.flex(22, weight: 600))
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
            }
            .font(VoiceIQUI.TypeScale.body())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiceIQUI.Spacing.xxl)
            .padding(.vertical, VoiceIQUI.Spacing.xl)
        }
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
