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
        func stopShowing() {}
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

    /// Hears a transcript, then the writer finds no speech in it.
    struct HeardThenNothing: TranscriptionServicing {
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            throw TranscriptionError.emptyTranscript
        }
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext,
                        live: RealtimeTranscription?,
                        onHeard: (@Sendable (String) -> Void)?) async throws -> TranscriptionResult {
            onHeard?("thank you")
            try? await Task.sleep(nanoseconds: 30_000_000)
            throw TranscriptionError.emptyTranscript
        }
    }

    /// A dictation that ends without written text takes its draft back out,
    /// so the field is as it was, and inserts nothing.
    func testADictationWithNoWrittenTextTakesItsDraftOut() async {
        let draft = FakeDraft(shows: .shown)
        let inserter = DraftingInserter(draft: draft)
        let capture = DictationCoordinatorTests.FakeCapture()
        let c = DictationCoordinator(audioFactory: { capture }, transcription: HeardThenNothing(),
                                     insertion: inserter, secureInputActive: { false })
        c.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        c.handle(.finalize)
        for _ in 0..<300 where !c.state.isTerminal { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(draft.events, ["show thank you", "replace ", "end"])
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertFalse(c.writingDraft)
    }

    /// An unconfirmed draft (the iPhone's) still gets its written text
    /// through `replace`, which names it.
    func testAPendingDraftIsReplacedNotInsertedBeside() async {
        let draft = FakeDraft(shows: .pending)
        let inserter = DraftingInserter(draft: draft)
        let c = await dictate(into: inserter)
        XCTAssertEqual(draft.events, ["show raw words", "replace Written words.", "end"])
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertFalse(c.writingDraft, "no writing animation for a draft nobody confirmed")
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
        /// Drafts whose insert lands late.
        var slow: Set<String> = []
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
            // A paste the app takes a while to show.
            if field.slow.contains(text) { try? await Task.sleep(nanoseconds: 200_000_000) }
            let at = field.value.utf16.count
            return field.ledger.add(id, text: text, at: at, over: 0, landedIn: field.value + text) == nil ? .lost : .shown
        }
        func replace(with text: String) async -> Bool {
            guard let span = field.ledger.draft(id), let new = span.replacing(in: field.value, with: text) else { return false }
            field.ledger.replace(id, with: text, landedIn: new)
            return true
        }
        func stopShowing() {}
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

    /// The second dictation is heard while the first's draft is still going
    /// in: it waits for it, so the drafts stand in spoken order, and each
    /// still swaps only its own text.
    func testALaterDraftWaitsForTheEarlierOneToLand() async {
        let field = Field("Notes:")
        field.slow = [" first one"]
        let script = Script([
            (heard: " first one", written: " First one.", delay: 500_000_000),
            (heard: " second one", written: " Second one.", delay: 50_000_000),
        ])
        let coordinator = DictationCoordinator(
            audioFactory: { DictationCoordinatorTests.FakeCapture() },
            transcription: script, insertion: field, secureInputActive: { false }
        )
        coordinator.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        try? await Task.sleep(nanoseconds: 20_000_000)  // heard, still landing
        XCTAssertEqual(field.value, "Notes:")
        coordinator.handle(.begin)
        for _ in 0..<8 { await Task.yield() }
        coordinator.handle(.finalize)
        await waitUntil { field.value.contains("second") || field.value.contains("Second") }
        XCTAssertTrue(field.value.hasPrefix("Notes: first one"), field.value)
        await waitUntil { !coordinator.hasBackgroundJobs && coordinator.state.isTerminal && field.value.contains("First") }
        XCTAssertEqual(field.value, "Notes: First one. Second one.")
    }

    #if os(macOS)
    /// A single-line field 200 pt wide whose draft runs past its right edge:
    /// the underline stops at the edge, a line out of view gets none, and the
    /// spinner stays inside the field.
    func testMarksStayInsideTheField() {
        let field = CGRect(x: 100, y: 500, width: 200, height: 22)
        XCTAssertEqual(FieldDraft.clipped(CGRect(x: 250, y: 503, width: 180, height: 16), to: field),
                       CGRect(x: 250, y: 503, width: 50, height: 16))
        XCTAssertNil(FieldDraft.clipped(CGRect(x: 320, y: 503, width: 100, height: 16), to: field))
        XCTAssertNil(FieldDraft.clipped(CGRect(x: 120, y: 540, width: 100, height: 16), to: field))

        let pastEdge = FieldDraft.spinnerSpot(for: CGRect(x: 430, y: 503, width: 0, height: 16), in: field)
        XCTAssertEqual(pastEdge?.minX, 300 - DraftOverlaySize.spinner - 5)
        XCTAssertEqual(FieldDraft.spinnerSpot(for: CGRect(x: 150, y: 503, width: 0, height: 16), in: field)?.minX, 150)
        XCTAssertNil(FieldDraft.spinnerSpot(for: CGRect(x: 150, y: 560, width: 0, height: 16), in: field))
    }

    /// A field that answers a range with its own frame (VS Code's search
    /// box) or with a block taller than a line gets no underline; a real
    /// wrapped draft keeps one per line, minus a line with no width.
    func testUnderlineOnlyOnTheText() {
        let field = CGRect(x: 50, y: 400, width: 270, height: 130)
        let character = CGRect(x: 58, y: 506, width: 8, height: 17)
        let lines = [CGRect(x: 58, y: 506, width: 240, height: 17), CGRect(x: 58, y: 488, width: 120, height: 17)]
        XCTAssertEqual(FieldDraft.onText(lines, character: character, field: field), lines)
        XCTAssertEqual(FieldDraft.onText(lines + [CGRect(x: 58, y: 470, width: 0, height: 17)],
                                         character: character, field: field), lines)

        XCTAssertEqual(FieldDraft.onText([field], character: character, field: field), [])
        XCTAssertEqual(FieldDraft.onText(lines, character: field, field: field), [])
        XCTAssertEqual(FieldDraft.onText(lines, character: field.insetBy(dx: 6, dy: 6), field: field), [])
        XCTAssertEqual(FieldDraft.onText([CGRect(x: 58, y: 470, width: 240, height: 53)],
                                         character: character, field: field), [])
        XCTAssertEqual(FieldDraft.onText(lines + [field.insetBy(dx: 1, dy: 1)], character: character, field: field), [])
        XCTAssertEqual(FieldDraft.onText(lines, character: CGRect(x: 58, y: 506, width: 0, height: 17), field: field), [])
    }
    #endif
}
