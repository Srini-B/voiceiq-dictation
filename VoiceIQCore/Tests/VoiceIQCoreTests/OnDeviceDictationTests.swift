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
}
