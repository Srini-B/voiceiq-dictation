import XCTest
import VoiceIQSpeech
@testable import VoiceIQCore

final class OnDeviceDictationTests: XCTestCase {
    private let service = GeminiTranscriptionService(client: GeminiClient(apiKey: { nil }))

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
        UserDefaults.standard.removeObject(forKey: "cleanupSource")
    }

    override func tearDown() { setUp() }

    /// With Gemini writing off, an on-device transcript goes in as
    /// transcribed, never to the network, and the Dictionary still fixes it.
    func testWritingOffKeepsTranscriptAndAppliesDictionary() async throws {
        SettingsStore().setCleanupSource(.none)
        _ = DictionaryStore().add(term: "Srini", misspelling: "Sreenie")
        let transcript = TranscriptionResult(rawTranscript: "ping sreenie on Slack", cleanedTranscript: "Ping Sreenie on Slack.",
                                             modelID: "fluid-speech-pro-local")
        let written = try await service.write(transcript, context: DictationContext())
        XCTAssertEqual(written.cleanedTranscript, "Ping Srini on Slack.")
        XCTAssertEqual(written.rawTranscript, "ping sreenie on Slack")
        XCTAssertEqual(written.modelID, "fluid-speech-pro-local")
    }

    /// History's Retry with Dictation On device and the model unavailable:
    /// the saved audio goes to Gemini unless writing is Off.
    func testRetryWithoutTheModelSendsAudioUnlessWritingIsOff() async throws {
        let settings = SettingsStore()
        settings.setDictationSource(.onDevice)
        defer { UserDefaults.standard.removeObject(forKey: "transcriptionSource") }
        let cloud = DictationCoordinatorTests.FakeTranscription()
        let retry = OnDeviceFirstTranscription(gemini: cloud, makeSession: { _, _, _, _ in fatalError("no session expected") })
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).caf")
        settings.setCleanupSource(.none)
        do {
            _ = try await retry.transcribe(audioURL: audio, durationSeconds: 3, context: DictationContext())
            XCTFail("expected onDeviceFailed with writing Off")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .onDeviceFailed)
        }
        XCTAssertEqual(cloud.audioCalls.value, 0)
        var expected = 0
        for writing in [CleanupSource.onDevice, .gemini] where CleanupSource.offered.contains(writing) {
            settings.setCleanupSource(writing)
            _ = try await retry.transcribe(audioURL: audio, durationSeconds: 3, context: DictationContext())
            expected += 1
            XCTAssertEqual(cloud.audioCalls.value, expected, "writing \(writing)")
        }
    }

    /// A decode with no words is an empty dictation, judged by the
    /// coordinator like an empty Gemini transcript, not an empty insert.
    func testEmptyTranscriptIsAnEmptyDictation() async {
        let transcript = TranscriptionResult(rawTranscript: "", cleanedTranscript: "  ", modelID: "fluid-speech-mini-local")
        do {
            _ = try await service.write(transcript, context: DictationContext())
            XCTFail("expected emptyTranscript")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .emptyTranscript)
        }
    }

    /// iPhone and iPad report less than their marketed memory: a 4 GB device
    /// gets Fluid Speech Mini, a 6 GB one Fluid Speech Pro.
    func testDeviceMemoryPicksTheModel() {
        XCTAssertEqual(LocalSpeechModel.suggested(physicalMemory: 3_900_000_000), .parakeet)
        XCTAssertEqual(LocalSpeechModel.suggested(physicalMemory: 5_700_000_000), .fluidSpeechPro)
        XCTAssertEqual(LocalSpeechModel.suggested(physicalMemory: 8_000_000_000), .fluidSpeechPro)
        XCTAssertFalse(LocalWriterSupport.isOffered(physicalMemory: 3_900_000_000))
        XCTAssertTrue(LocalWriterSupport.isOffered(physicalMemory: 5_700_000_000))
    }

    /// Hesitation sounds and a spoken "period" written as ".." are removed
    /// before the on-device writer sees RAW; words that only contain those
    /// sounds stay, and a dictation of nothing but hesitation is not sent.
    func testOnDeviceWriterInputDropsHesitationOnly() {
        XCTAssertEqual(PromptOnDevice.prepared("Um, tell Uhura the summer plan .. Uh thanks ..", english: true),
                       "tell Uhura the summer plan. thanks.")
        XCTAssertEqual(PromptOnDevice.prepared("Er kommt um 3 Uhr ..", english: false), "Er kommt um 3 Uhr.")
        XCTAssertTrue(PromptOnDevice.isOnlyHesitation("Um, uh, hun.", english: true))
        XCTAssertFalse(PromptOnDevice.isOnlyHesitation("Um, send it.", english: true))
        XCTAssertFalse(PromptOnDevice.isOnlyHesitation("10:30", english: true))
        XCTAssertFalse(PromptOnDevice.isOnlyHesitation("Er.", english: false))
        XCTAssertEqual(PromptOnDevice.text(fromAnswer: #"{"text": "Dear Priya,\n\nThanks."}"#), "Dear Priya,\n\nThanks.")
        XCTAssertEqual(PromptOnDevice.text(fromAnswer: #"{"text": "\#(PromptV1.noSpeechToken)"}"#), "")
        XCTAssertNil(PromptOnDevice.text(fromAnswer: "Here is the cleaned text"))
    }

    /// A meeting too long for the on-device notes keeps its start and end,
    /// also when one speaker talked through most of it.
    func testOnDeviceNotesKeepBothEndsOfAnOversizedTurn() {
        let long = "S1: opening " + String(repeating: "word ", count: 2_000) + "closing remark"
        let fitted = MeetingNotesPrompt.fitted([long, "S2: final decision"], characters: 2_000)
        XCTAssertLessThanOrEqual(fitted.count, 2_200)
        XCTAssertTrue(fitted.contains("S1: opening"))
        XCTAssertTrue(fitted.contains("S2: final decision"))
    }
}
