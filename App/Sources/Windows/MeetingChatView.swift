import VoiceIQCore
import SwiftUI

/// The questions asked about a meeting and their answers, below the notes.
struct MeetingChatTurns: View {
    @ObservedObject var chat: MeetingChatModel
    let scroller: ScrollViewProxy

    private static let end = "meeting-chat-end"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            turns
            Color.clear.frame(height: 0).id(Self.end)
        }
        .onAppear {
            // Narrow, sending from the transcript brings the notes back with the
            // question already out; its change happened before this view existed.
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

    @ViewBuilder private var turns: some View {
        if !chat.turns.isEmpty || chat.state != .idle {
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.m) {
                Text("Questions").font(GTFont.flex(15, weight: 600))
                ForEach(chat.turns) { turn in
                    question(turn.question).id(turn.id)
                    MarkdownView(turn.answer)
                }
                switch chat.state {
                case .idle:
                    EmptyView()
                case .asking(let text):
                    question(text)
                    HStack(spacing: VoiceIQUI.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Thinking").foregroundStyle(.secondary)
                    }
                case .failed(let text, let message):
                    question(text)
                    HStack(alignment: .firstTextBaseline, spacing: VoiceIQUI.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VoiceIQUI.Colors.error)
                        Text(message).foregroundStyle(VoiceIQUI.Colors.error).fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { chat.ask(text) }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func question(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, VoiceIQUI.Spacing.s)
            .padding(.vertical, VoiceIQUI.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).fill(VoiceIQUI.Colors.primaryContainer))
            .foregroundStyle(VoiceIQUI.Colors.onPrimaryContainer)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, VoiceIQUI.Spacing.xxxl)
    }
}

/// The question box along the bottom of the meeting.
struct MeetingChatInput: View {
    @ObservedObject var chat: MeetingChatModel
    /// After a question is sent.
    var sent: () -> Void = {}
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: VoiceIQUI.Spacing.xs) {
            TextField("Ask about this meeting", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, VoiceIQUI.Spacing.s)
                .padding(.vertical, VoiceIQUI.Spacing.xs)
                .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).fill(VoiceIQUI.Colors.surfaceContainer))
                .overlay(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large)
                    .strokeBorder(focused ? VoiceIQUI.Colors.primary : VoiceIQUI.Colors.outlineVariant))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canSend ? VoiceIQUI.Colors.primary : VoiceIQUI.Colors.outlineVariant)
            .disabled(!canSend)
            .help("Ask")
        }
        .font(VoiceIQUI.TypeScale.body())
        .padding(.horizontal, VoiceIQUI.Spacing.xxl)
        .padding(.vertical, VoiceIQUI.Spacing.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool { !chat.isAsking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        chat.ask(draft)
        draft = ""
        sent()
    }
}
