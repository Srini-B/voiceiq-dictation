import SwiftUI
import UIKit
import VoiceIQBridge

/// The typing keyboard as the current settings draw it, built from the
/// keyboard's own key views (`KeyboardKeysView`, `KeyTheme`, `KeyLayout`), so
/// every change in Settings › Typing shows here as the keyboard will look.
/// The keys respond to touches, including slides, but type nothing.
struct KeyboardPreview: View {
    let preferences: KeyboardPreferences

    private var theme: KeyTheme { KeyTheme.make(preferences) }

    var body: some View {
        VStack(spacing: 0) {
            bar.frame(height: 44)
            PreviewKeys(preferences: preferences, theme: theme)
        }
        .frame(height: preferences.keyboardHeight(compact: false))
        // Room the system's globe and mic strip gives the keys on a phone.
        .padding(.bottom, 8)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .modifier(ForcedScheme(style: theme.style))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard preview")
    }

    private var bar: some View {
        HStack(spacing: 0) {
            Image(systemName: "waveform").frame(width: 40)
                .foregroundStyle(Theme.Colors.accent)
            if preferences.predictions {
                ForEach(Array(["I", "The", "I'm"].enumerated()), id: \.offset) { index, word in
                    if index > 0 { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 22) }
                    Text(word).font(.system(size: 16)).frame(maxWidth: .infinity)
                }
            } else {
                Spacer()
            }
            Image(systemName: "mic.fill").frame(width: 40)
                .foregroundStyle(Theme.Colors.accent)
        }
        .font(.system(size: 17))
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var background: some View {
        if let background = theme.background {
            LinearGradient(colors: [Color(background.top), Color(background.bottom)], startPoint: .top, endPoint: .bottom)
        } else {
            // The system keyboard's backdrop, which Default and Clear sit on.
            Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(white: 0.17, alpha: 1)
                : UIColor(red: 0.84, green: 0.85, blue: 0.88, alpha: 1) })
        }
    }
}

/// A forced key tone pins the preview to light or dark, as it pins the keyboard.
private struct ForcedScheme: ViewModifier {
    let style: UIUserInterfaceStyle

    func body(content: Content) -> some View {
        switch style {
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        default: content
        }
    }
}

private struct PreviewKeys: UIViewRepresentable {
    let preferences: KeyboardPreferences
    let theme: KeyTheme

    func makeUIView(context: Context) -> KeyboardKeysView {
        let view = KeyboardKeysView()
        view.shift = .once
        return view
    }

    func updateUIView(_ view: KeyboardKeysView, context: Context) {
        view.overrideUserInterfaceStyle = theme.style
        view.theme = theme
        view.slideToType = preferences.slideToType
        view.rows = KeyLayout.rows(page: .letters, layout: preferences.layout,
                                   field: FieldTraits(showsGlobe: false), numberRow: preferences.numberRow)
    }
}
