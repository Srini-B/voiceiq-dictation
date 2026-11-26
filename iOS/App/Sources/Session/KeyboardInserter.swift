import Foundation
import VoiceIQBridge
import VoiceIQCore

/// Where the dictation in progress came from and where its text goes.
@MainActor
final class DictationTarget {
    struct Fields: Equatable {
        /// The app Dictate was tapped in, for History and the writing model.
        var host: String?
        /// The field Dictate was tapped in.
        var origin: FieldIdentity?
        /// The field Stop was tapped in, when a keyboard stopped it.
        var stoppedIn: FieldIdentity?
        /// When the user stopped it, from a keyboard or from outside one.
        var stoppedAt: Date?
    }

    var fields = Fields()

    var host: String? { fields.host }

    /// The text goes where Stop was tapped. Stopped from outside a keyboard
    /// (Dynamic Island, Action button, a call), it goes back to where it
    /// started.
    var destination: FieldIdentity? { fields.stoppedIn ?? fields.origin }
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
