import UIKit

/// Hex's keyboard keeps its text target for its whole life (`EmojiRoutedTarget.document`),
/// and `TypingController` keeps the keyboard, so passing the controller itself would
/// keep both alive after iOS lets the keyboard go. This forwards to it without owning it.
@MainActor
final class WeakTextTarget: KeyboardTextTarget {
    private weak var base: TypingController?

    init(_ base: TypingController) {
        self.base = base
    }

    var documentContextBeforeInput: String? { base?.documentContextBeforeInput }
    var hasText: Bool { base?.hasText ?? false }
    var autocapitalizationType: UITextAutocapitalizationType? { base?.autocapitalizationType }
    var autocorrectionType: UITextAutocorrectionType? { base?.autocorrectionType }
    var keyboardType: UIKeyboardType? { base?.keyboardType }
    var returnKeyType: UIReturnKeyType? { base?.returnKeyType }
    var enablesReturnKeyAutomatically: Bool? { base?.enablesReturnKeyAutomatically }
    var keyboardAppearance: UIKeyboardAppearance? { base?.keyboardAppearance }
    var textContentType: UITextContentType? { base?.textContentType ?? nil }
    var isSecureTextEntry: Bool? { base?.isSecureTextEntry }
    func insertText(_ text: String) { base?.insertText(text) }
    func deleteBackward() { base?.deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) { base?.adjustTextPosition(byCharacterOffset: offset) }
}
