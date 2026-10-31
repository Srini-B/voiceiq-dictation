import SwiftUI
import UIKit

/// Three suggestions, best in the middle, as on the iOS keyboard. Typed
/// letters show in quotes on the left; the word space will put in is
/// highlighted.
struct SuggestionStrip: View {
    let suggestions: [Suggestion]
    let theme: KeyTheme
    let pick: (Suggestion) -> Void
    /// Holding a suggestion.
    let hold: (Suggestion) -> Void

    private var ordered: [Suggestion] {
        guard suggestions.count > 1, suggestions[0].kind != .typed else { return suggestions }
        return [suggestions[1], suggestions[0]] + suggestions.dropFirst(2)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ordered.prefix(3).enumerated()), id: \.offset) { index, suggestion in
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 22)
                }
                Text(suggestion.kind == .typed ? "“\(suggestion.text)”" : suggestion.text)
                    .font(.system(size: suggestion.kind == .emoji ? 22 : 16))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if suggestion.kind == .autocorrection || suggestion.kind == .replacement {
                            RoundedRectangle(cornerRadius: 7).fill(Color(theme.popup)).padding(.vertical, 5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { pick(suggestion) }
                    .onLongPressGesture(minimumDuration: 0.5) { hold(suggestion) }
                    .accessibilityAddTraits(.isButton)
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// Shown after holding a suggestion: blocks the word for good.
struct BlockWordChip: View {
    let word: String
    let block: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: block) {
                Text("Don’t Suggest “\(word)”")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(Color(.secondarySystemFill)))
            }
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

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

/// The UIKit key area inside the SwiftUI keyboard.
struct KeysArea: UIViewRepresentable {
    @ObservedObject var typing: TypingController
    let controller: UIInputViewController

    func makeUIView(context: Context) -> KeyboardKeysView {
        let view = KeyboardKeysView()
        view.inputController = controller
        view.delegate = typing
        view.onLayout = { [weak typing] geometry in DispatchQueue.main.async { typing?.geometryChanged(geometry) } }
        return view
    }

    func updateUIView(_ view: KeyboardKeysView, context: Context) {
        view.rows = KeyLayout.rows(page: typing.page, layout: typing.preferences.layout, field: typing.field,
                                   numberRow: typing.preferences.numberRow)
        view.shift = typing.shift
        view.slideToType = typing.preferences.slideToType
        view.spaceSlide = typing.preferences.spaceSlide
        view.deleteSlide = typing.preferences.deleteSlide
        // A forced key tone (and iOS 5, which has no dark look) pins only the
        // keys: the bar sits on the system's backdrop, which follows the app.
        view.overrideUserInterfaceStyle = typing.theme.style
        view.theme = typing.theme
        view.returnEnabled = typing.returnEnabled
    }
}
