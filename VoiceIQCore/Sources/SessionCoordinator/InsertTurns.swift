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
        fileprivate let previousPlaced: Gate?
        fileprivate let placed: Gate

        /// Returns once every earlier job has inserted or given up.
        func waitForPrevious() async {
            await previous?.wait()
        }

        /// Returns once every earlier job's text is in the field, as a
        /// draft or written, or it gave up. A draft goes in after the
        /// drafts spoken before it, without waiting for their writers.
        func waitForPreviousPlaced() async {
            await previousPlaced?.wait()
        }

        /// This job's text is in the field (or never will be); the next
        /// job's draft may go in after it. Never ahead of an earlier job.
        func markPlaced() {
            Task { @MainActor [previousPlaced, placed] in
                await previousPlaced?.wait()
                placed.open()
            }
        }

        /// Frees the next job's turn, but never ahead of an earlier job: a job
        /// that fails or is cancelled while the one before it still runs
        /// passes its turn on only when that one is done. Safe to call twice.
        func finish() {
            markPlaced()
            Task { @MainActor [previous, done] in
                await previous?.wait()
                done.open()
            }
        }
    }

    private var last: Gate?
    private var lastPlaced: Gate?

    func take() -> Ticket {
        let done = Gate(), placed = Gate()
        defer { last = done; lastPlaced = placed }
        return Ticket(previous: last, done: done, previousPlaced: lastPlaced, placed: placed)
    }
}
