import Foundation

/// The transcript of a live session, one slot per turn the client closed.
///
/// Finals are placed by turn, never by arrival. Gemini has no item IDs and
/// finishes turns in order, so its finals fill the oldest unfinished turn.
/// OpenAI's commits are acknowledged in send order, which fixes each item's
/// turn, and its completions are placed by item ID however late or early they
/// arrive. A session is complete only when every closed turn is finished, so
/// the last turn's words cannot be left behind by an earlier turn's text.
struct LiveTurnLedger {
    private var texts: [Int: String] = [:]
    private var finished: Set<Int> = []
    /// Gemini: the oldest turn the server has not finished.
    private var cursor = 0
    /// OpenAI: commits acknowledged so far, and the turn each item belongs to.
    private var commits = 0
    private var turnOfItem: [String: Int] = [:]
    /// OpenAI completions that arrived before their commit acknowledgement.
    private var earlyFinals: [String: String] = [:]

    /// Number of finals applied, for the log.
    private(set) var finalCount = 0

    mutating func applyFinal(_ text: String) {
        texts[cursor, default: ""] += texts[cursor, default: ""].isEmpty ? text : " " + text
        finalCount += 1
    }

    /// Ignored unless the client has closed the turn: a completion for a turn
    /// still open would mark it finished before its last words arrived.
    mutating func applyTurnComplete(closedTurns: Int) {
        guard cursor < closedTurns else { return }
        finished.insert(cursor)
        cursor += 1
    }

    mutating func applyCommitted(itemID: String) {
        guard turnOfItem[itemID] == nil else { return }
        turnOfItem[itemID] = commits
        commits += 1
        if let text = earlyFinals.removeValue(forKey: itemID) { place(itemID: itemID, text: text) }
    }

    mutating func applyItemFinal(itemID: String, text: String) {
        finalCount += 1
        guard turnOfItem[itemID] != nil else {
            earlyFinals[itemID] = text
            return
        }
        place(itemID: itemID, text: text)
    }

    /// True when every one of the first `turns` turns is finished.
    func isComplete(turns: Int) -> Bool {
        (0..<turns).allSatisfy { finished.contains($0) }
    }

    func isFinished(turn: Int) -> Bool { finished.contains(turn) }

    /// The finished turns' text, in turn order.
    var transcript: String {
        finished.sorted().compactMap { texts[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private mutating func place(itemID: String, text: String) {
        guard let turn = turnOfItem[itemID] else { return }
        texts[turn] = text
        finished.insert(turn)
    }
}
