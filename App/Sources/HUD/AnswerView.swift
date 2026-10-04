import AppKit
import SwiftUI

struct AnswerView: View {
    let answer: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PillDragHandle()
                    .fixedSize()
                    .accessibilityLabel("Move answer")
                Text("Answer")
                    .font(.headline)
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Button {
                    NotificationCenter.default.post(name: .pillAnswerDismissed, object: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close answer")
            }

            ScrollView {
                MarkdownView(answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiceIQUI.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        copied = true
    }
}

extension Notification.Name {
    static let pillAnswerDismissed = Notification.Name("io.blue.voiceiq.pill.answer.dismissed")
}
