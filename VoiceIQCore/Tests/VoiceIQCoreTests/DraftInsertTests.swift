import XCTest
import VoiceIQBridge
@testable import VoiceIQCore

/// The transcript shown in the field as a draft while the writing model
/// runs, then swapped for the written text.
@MainActor
final class DraftInsertTests: XCTestCase {
    /// Hears "raw words", then writes "Written words." a beat later.
    struct HearingTranscription: TranscriptionServicing {
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            TranscriptionResult(rawTranscript: "raw words", cleanedTranscript: "Written words.", modelID: "test")
        }
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                        live: RealtimeTranscription?,
                        onHeard: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            onHeard?("raw words")
            try? await Task.sleep(nanoseconds: 30_000_000)
            return try await transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
        }
    }

    final class FakeDraft: TextDraft {
        var shows: DraftShown
        var replaces: Bool
        private(set) var events: [String] = []
        init(shows: DraftShown, replaces: Bool = true) {
            self.shows = shows
            self.replaces = replaces
        }
        func show(_ text: String) async -> DraftShown { events.append("show \(text)"); return shows }
        func replace(with text: String) async -> Bool { events.append("replace \(text)"); return replaces }
        func end() { events.append("end") }
    }

    final class DraftingInserter: TextInserting {
        let draft: FakeDraft?
        private(set) var inserted: [String] = []
        init(draft: FakeDraft?) { self.draft = draft }
        func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
            inserted.append(text)
            return .inserted
        }
        func draft(context: DictationContext) async -> TextDraft? { draft }
    }

    private var sandbox: URL!

    override func setUp() async throws {
        try await super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-tests-\(UUID().uuidString)", isDirectory: true)
        FileLayout.overrideRoot = sandbox
    }

    override func tearDown() async throws {
        FileLayout.overrideRoot = nil
        try? FileManager.default.removeItem(at: sandbox)
        try await super.tearDown()
    }

    private func dictate(into inserter: DraftingInserter) async -> DictationCoordinator {
        let capture = DictationCoordinatorTests.FakeCapture()
        let coordinator = DictationCoordinator(
            audioFactory: { capture },
            transcription: HearingTranscription(),
            insertion: inserter,
            secureInputActive: { false }
        )
        coordinator.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        for _ in 0..<300 where !coordinator.state.isTerminal {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return coordinator
    }

    func testTheDraftIsSwappedForTheWrittenTextAndNothingIsInsertedTwice() async {
        let draft = FakeDraft(shows: .shown)
        let inserter = DraftingInserter(draft: draft)
        let c = await dictate(into: inserter)
        XCTAssertEqual(c.state, .done(.inserted))
        XCTAssertEqual(draft.events, ["show raw words", "replace Written words.", "end"])
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertNil(c.insertedNotice)
        XCTAssertFalse(c.writingDraft)
    }

    /// A field that took nothing gets the written text by the usual insert.
    func testADraftThatNeverWentInLeavesTheInsertToTheLadder() async {
        let draft = FakeDraft(shows: .notInserted)
        let inserter = DraftingInserter(draft: draft)
        _ = await dictate(into: inserter)
        XCTAssertEqual(inserter.inserted, ["Written words."])
        XCTAssertFalse(draft.events.contains { $0.hasPrefix("replace") })
    }

    /// A draft that may have gone in but can't be found stays, and the
    /// written text does not go in beside it.
    func testALostDraftIsNeitherReplacedNorInsertedAgain() async {
        let draft = FakeDraft(shows: .lost)
        let inserter = DraftingInserter(draft: draft)
        let c = await dictate(into: inserter)
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(c.insertedNotice, DictationCoordinator.keptDraftNotice)
        XCTAssertEqual(c.lastResult, "Written words.")
    }

    /// The user edited the draft: it stays, with a note, and Paste last
    /// holds the written text.
    func testAnEditedDraftStaysWithANote() async {
        let draft = FakeDraft(shows: .shown, replaces: false)
        let inserter = DraftingInserter(draft: draft)
        let c = await dictate(into: inserter)
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(c.insertedNotice, DictationCoordinator.keptDraftNotice)
        XCTAssertEqual(c.lastResult, "Written words.")
    }

    // MARK: Back-to-back dictations into one field

    /// One dictation per call, in order: what it hears and, after `delay`,
    /// what the writer returns.
    final class Script: TranscriptionServicing, @unchecked Sendable {
        private var lines: [(heard: String, written: String, delay: UInt64)]
        init(_ lines: [(heard: String, written: String, delay: UInt64)]) { self.lines = lines }
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            fatalError("drafts come through the streamed path")
        }
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                        live: RealtimeTranscription?,
                        onHeard: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            let line = await MainActor.run { lines.removeFirst() }
            onHeard?(line.heard)
            try? await Task.sleep(nanoseconds: line.delay)
            return TranscriptionResult(rawTranscript: line.heard, cleanedTranscript: line.written, modelID: "test")
        }
    }

    /// A text field: the caret stays at the end, and the user can type
    /// anywhere. Drafts are followed by the real `DraftLedger`.
    final class Field: TextInserting {
        var ledger: DraftLedger
        init(_ value: String) { ledger = DraftLedger(value: value) }
        var value: String { ledger.value }
        func type(_ new: String) { ledger.observe(new) }
        func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
            ledger.observe(ledger.value + text)
            return .inserted
        }
        func draft(context: DictationContext) async -> TextDraft? { FieldDraftFake(field: self) }
    }

    final class FieldDraftFake: TextDraft {
        let field: Field
        let id = UUID()
        init(field: Field) { self.field = field }
        func show(_ text: String) async -> DraftShown {
            let at = field.value.utf16.count
            return field.ledger.add(id, text: text, at: at, over: 0, landedIn: field.value + text) == nil ? .lost : .shown
        }
        func replace(with text: String) async -> Bool {
            guard let span = field.ledger.draft(id), let new = span.replacing(in: field.value, with: text) else { return false }
            field.ledger.replace(id, with: text, landedIn: new)
            return true
        }
        func end() { field.ledger.remove(id) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    /// Two dictations into one field, the second spoken while the first's
    /// writer still runs, and its writer answering first. Each swaps only
    /// its own draft; the text before them and the text the user typed
    /// between them stay as they were.
    func testOverlappingDictationsEachSwapOnlyTheirOwnDraft() async {
        let field = Field("Earlier dictation, already written.")
        let script = Script([
            (heard: " um first one", written: " First one.", delay: 400_000_000),
            (heard: " second one", written: " Second one.", delay: 20_000_000),
        ])
        let coordinator = DictationCoordinator(
            audioFactory: { DictationCoordinatorTests.FakeCapture() },
            transcription: script, insertion: field, secureInputActive: { false }
        )
        coordinator.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        await waitUntil { field.value.hasSuffix(" um first one") }
        XCTAssertTrue(coordinator.writingDraft)
        field.type(field.value + " (typed)")

        coordinator.handle(.begin)  // the first job goes on in the background
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        await waitUntil { field.value.hasSuffix(" Second one.") }
        XCTAssertEqual(field.value, "Earlier dictation, already written. um first one (typed) Second one.",
                       "the second swapped while the first was still a draft")

        await waitUntil { !coordinator.hasBackgroundJobs && coordinator.state.isTerminal }
        XCTAssertEqual(field.value, "Earlier dictation, already written. First one. (typed) Second one.")
        XCTAssertFalse(coordinator.writingDraft)
    }

    /// The same words dictated twice: each dictation swaps its own copy.
    func testTheSameWordsTwiceAreSwappedByPlaceNotBySearch() async {
        let field = Field("")
        let script = Script([
            (heard: "ok", written: "OK,", delay: 300_000_000),
            (heard: " ok", written: " Okay.", delay: 10_000_000),
        ])
        let coordinator = DictationCoordinator(
            audioFactory: { DictationCoordinatorTests.FakeCapture() },
            transcription: script, insertion: field, secureInputActive: { false }
        )
        coordinator.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        await waitUntil { field.value == "ok" }
        coordinator.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        await waitUntil { !coordinator.hasBackgroundJobs && coordinator.state.isTerminal && field.value.hasPrefix("OK") }
        XCTAssertEqual(field.value, "OK, Okay.")
    }
}
