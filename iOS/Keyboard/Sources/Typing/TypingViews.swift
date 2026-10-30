import SwiftUI
import UIKit

/// Three suggestions, best in the middle, as on the iOS keyboard. Typed
/// letters show in quotes on the left; the word space will put in is
/// highlighted.
struct SuggestionStrip: View {
    let suggestions: [Suggestion]
    let theme: KeyTheme
    let pick: (Suggestion) -> Void

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
                Button { pick(suggestion) } label: {
                    Text(suggestion.kind == .typed ? "“\(suggestion.text)”" : suggestion.text)
                        .font(.system(size: 16))
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
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
        // A forced key tone (and iOS 5, which has no dark look) pins only the
        // keys: the bar sits on the system's backdrop, which follows the app.
        view.overrideUserInterfaceStyle = typing.theme.style
        view.theme = typing.theme
        view.returnEnabled = typing.returnEnabled
    }
}
