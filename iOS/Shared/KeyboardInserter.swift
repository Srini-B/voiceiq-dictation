import VoiceIQBridge
import VoiceIQCore

@MainActor
final class DictationTarget {
    var host: String?
}

/// Hands results to the keyboard. The keyboard does the actual typing.
@MainActor
final class KeyboardInserter: TextInserting {
    var onDeliver: ((String, KeyboardMode) -> Void)?

    func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        let mode: KeyboardMode
        switch context.mode {
        case .dictate: mode = .dictate
        case .translate: mode = .translate
        case .askAnything: mode = .ask
        // The iPhone never starts an agent session; its transcript is
        // handed to the caller, not inserted. Deliver as plain text.
        case .agent: mode = .dictate
        }
        onDeliver?(text, mode)
        return .inserted
    }
}
