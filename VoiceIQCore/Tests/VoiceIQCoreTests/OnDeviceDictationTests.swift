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
    }
}
