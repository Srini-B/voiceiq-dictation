import VoiceIQBridge
import VoiceIQCore

@MainActor
final class DictationTarget {
    var host: String?
}

/// Hands results to the keyboard. The keyboard does the actual typing.
@MainActor
final class KeyboardInserter: TextInserting {
    var onDeliver: ((String) -> Void)?

    func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        onDeliver?(text)
        return .inserted
    }
}
