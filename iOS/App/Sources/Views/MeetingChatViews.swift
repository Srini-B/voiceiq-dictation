import SwiftUI
import VoiceIQCore

/// The questions asked about a note and their answers, below the notes.
struct MeetingChatTurns: View {
    @ObservedObject var chat: MeetingChatModel
    let scroller: ScrollViewProxy

    private static let end = "meeting-chat-end"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if !chat.turns.isEmpty || chat.state != .idle {
                GroupLabel(text: "Questions")
                ForEach(chat.turns) { turn in
                    question(turn.question).id(turn.id)
                    answer(turn.answer)
                }
                switch chat.state {
                case .idle:
                    EmptyView()
                case .asking(let text):
                    question(text)
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().tint(Theme.Colors.accent)
                        Text("Thinking").font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.muted)
                    }
                case .failed(let text, let message):
                    question(text)
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(message).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.recording)
                        Button("Try again") { chat.ask(text) }.font(Theme.Fonts.label())
                    }
                }
            }
            Color.clear.frame(height: 0).id(Self.end)
        }
        .onAppear {
            // Reopening a note while its question is out: that change happened before this view existed.
            guard chat.isAsking else { return }
            DispatchQueue.main.async { scroller.scrollTo(Self.end, anchor: .bottom) }
        }
        .onChange(of: chat.state) { _, state in
            // A new answer opens at its question; a question in flight or an error shows at the end.
            withAnimation {
                if state == .idle, let last = chat.turns.last { scroller.scrollTo(last.id, anchor: .top) }
                else { scroller.scrollTo(Self.end, anchor: .bottom) }
            }
        }
    }

    private func question(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body())
            .foregroundStyle(Theme.Colors.onAccent)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.accent))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Theme.Spacing.xxl)
    }

    private func answer(_ markdown: String) -> some View {
        let text = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        return Text(text).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink).textSelection(.enabled)
    }
}

/// The question box pinned to the bottom of a note.
struct MeetingChatInput: View {
    @ObservedObject var chat: MeetingChatModel
    @State private var draft = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            // One line: a vertical field on iOS takes Return as a new line, not Send.
            TextField("Ask about this note", text: $draft)
                .font(Theme.Fonts.body())
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.field).fill(Theme.Colors.surfaceNested))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .foregroundStyle(canSend ? Theme.Colors.accent : Theme.Colors.muted)
            .disabled(!canSend)
            .accessibilityLabel("Ask")
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.s)
        .background(.bar)
    }

    private var canSend: Bool { !chat.isAsking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        chat.ask(draft)
        draft = ""
    }
}
