import Foundation

/// Dictations insert in the order they were spoken, even when a later one is
/// transcribed first. Each job takes a ticket when its audio is final and waits
/// for the ticket before it; Hex orders its outputs the same way
/// (anomalyco/hex, `OrderedOutputs` in `src/parakeet.rs`, MIT).
@MainActor
final class InsertTurns {
    /// Opens once, and lets every waiter through from then on.
    @MainActor final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    struct Ticket: Sendable {
        fileprivate let previous: Gate?
        fileprivate let done: Gate

        /// Returns once every earlier job has inserted or given up.
        func waitForPrevious() async {
            await previous?.wait()
        }

        /// Frees the next job's turn, but never ahead of an earlier job: a job
        /// that fails or is cancelled while the one before it still runs
        /// passes its turn on only when that one is done. Safe to call twice.
        func finish() {
            Task { @MainActor [previous, done] in
                await previous?.wait()
                done.open()
            }
        }
    }

    private var last: Gate?

    func take() -> Ticket {
        let done = Gate()
        defer { last = done }
        return Ticket(previous: last, done: done)
    }
}
