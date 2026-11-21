import SwiftUI
import UIKit

/// The bar while searching emoji: the query, then what it finds.
struct EmojiSearchBar: View {
    @ObservedObject var typing: TypingController

    var body: some View {
        let query = typing.emojiQuery ?? ""
        HStack(spacing: 6) {
            Button(action: typing.closeEmojiSearch) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 32).frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close Search")
            Text(query.isEmpty ? "Search Emoji" : query)
                .font(.system(size: 15))
                .foregroundStyle(query.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize()
            // No scroll view: iOS 26 blurs a scroll view's edges, which in a
            // bar this short is all of it. Typing more narrows the list.
            HStack(spacing: 0) {
                ForEach(EmojiData.search(query, limit: 8), id: \.self) { emoji in
                    Button { typing.insertEmoji(emoji) } label: {
                        Text(emoji).font(.system(size: 26)).frame(width: 40, height: 36).contentShape(Rectangle())
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// Hex's keys inside the SwiftUI keyboard: its suggestion strip, the Hex key
/// (VoiceiQ's dictation) and the keys.
struct KeysArea: UIViewRepresentable {
    let typing: TypingController

    func makeUIView(context: Context) -> FullKeyboardView { typing.makeKeyboard() }

    func updateUIView(_ view: FullKeyboardView, context: Context) {}
}
