import Foundation

/// Dictations insert in the order they were spoken, even when a later one is
/// transcribed first. Each job takes a ticket when its audio is final and waits
/// for the ticket before it; Hex orders its outputs the same way
/// (anomalyco/hex, `OrderedOutputs` in `src/parakeet.rs`, MIT).
@MainActor
final class InsertTurns {
    struct Ticket: Sendable {
        fileprivate let previous: AsyncStream<Void>?
        fileprivate let done: AsyncStream<Void>.Continuation

        /// Returns once the job before this one has inserted or given up.
        func waitForPrevious() async {
            guard let previous else { return }
            for await _ in previous {}
        }

        /// Frees the next job's turn. Safe to call more than once.
        func finish() { done.finish() }
    }

    private var last: AsyncStream<Void>?

    func take() -> Ticket {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { last = stream }
        return Ticket(previous: last, done: continuation)
    }
}
