import UIKit

/// Breaks the retain cycle between `FullKeyboardView` (which retains its text
/// target via `EmojiRoutedTarget.document`) and `TypingBridge` (which owns the
/// keyboard view).
@MainActor
final class WeakTextTarget: KeyboardTextTarget {
    private weak var base: TypingBridge?

    init(_ base: TypingBridge) {
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
    var documentContextAfterInput: String? { base?.documentContextAfterInput }
    var selectedText: String? { base?.selectedText }
    var smartQuotesType: UITextSmartQuotesType? { base?.smartQuotesType }
    var smartDashesType: UITextSmartDashesType? { base?.smartDashesType }
    var documentIdentifier: UUID? { base?.documentIdentifier }
    func insertText(_ text: String) { base?.insertText(text) }
    func deleteBackward() { base?.deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) { base?.adjustTextPosition(byCharacterOffset: offset) }
}
