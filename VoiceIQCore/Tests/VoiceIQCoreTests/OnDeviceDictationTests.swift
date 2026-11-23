import XCTest
import VoiceIQSpeech
@testable import VoiceIQCore

final class OnDeviceDictationTests: XCTestCase {
    private let service = GeminiTranscriptionService(client: GeminiClient(apiKey: { nil }))

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
        UserDefaults.standard.removeObject(forKey: "cleanupSource")
        UserDefaults.standard.removeObject(forKey: "onDeviceSpeechLanguage")
    }

    override func tearDown() { setUp() }

    /// With Gemini writing off, an on-device transcript goes in as
    /// transcribed, never to the network, and the Dictionary still fixes it,
    /// sound-alike spellings included.
    func testWritingOffKeepsTranscriptAndAppliesDictionary() async throws {
        SettingsStore().setCleanupSource(.none)
        SettingsStore().setLocalSpeechLanguage("en-US")
        _ = DictionaryStore().add(term: "Srini", misspelling: "Sreenie")
        _ = DictionaryStore().add(term: "Stacey", misspelling: nil)
        let transcript = TranscriptionResult(rawTranscript: "ping sreenie on Slack", cleanedTranscript: "Ping Sreenie and Stacy on Slack.",
                                             modelID: "fluid-speech-pro-local")
        let written = try await service.write(transcript, context: DictationContext())
        XCTAssertEqual(written.cleanedTranscript, "Ping Srini and Stacey on Slack.")
        XCTAssertEqual(written.rawTranscript, "ping sreenie on Slack")
        XCTAssertEqual(written.modelID, "fluid-speech-pro-local")
    }

    /// History's Retry with Dictation On device and the model unavailable:
    /// the saved audio goes to Gemini whatever the writing choice.
    func testRetryWithoutTheModelSendsAudioToGemini() async throws {
        let settings = SettingsStore()
        settings.setDictationSource(.onDevice)
        defer { UserDefaults.standard.removeObject(forKey: "transcriptionSource") }
        let cloud = DictationCoordinatorTests.FakeTranscription()
        let retry = OnDeviceFirstTranscription(gemini: cloud, makeSession: { _, _, _, _ in fatalError("no session expected") })
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).caf")
        var expected = 0
        for writing in [CleanupSource.none, .onDevice, .gemini] where CleanupSource.offered.contains(writing) {
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

    /// Core ML's prepared copies of the models (on the Mac, about 1 GB in
    /// `~/Library/Caches/io.blue.voiceiq.localspeech`) go when a model is
    /// deleted, and a launch with no model downloaded removes copies an older
    /// build left behind. While a model is downloaded, the launch keeps them.
    func testPreparedModelsGoWithTheModels() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        FileLayout.overrideRoot = root
        defer {
            FileLayout.overrideRoot = nil
            try? fileManager.removeItem(at: root)
        }
        let cache = LocalModelInstaller.preparedModelCache
        func prepare() throws {
            let bundle = cache.appendingPathComponent("com.apple.e5rt.e5bundlecache/25A1/model.bundle", isDirectory: true)
            try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("program".utf8).write(to: bundle.appendingPathComponent("main.e5"))
        }

        let manifest = LocalModelManifest.speakerDiarizer
        for file in manifest.files {
            let url = manifest.installDirectory.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(fileManager.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.size))
            try handle.close()
        }
        try Data(manifest.revision.utf8).write(to: manifest.installDirectory.appendingPathComponent(LocalModelManifest.markerName))
        XCTAssertTrue(LocalModelInstaller.isInstalled(manifest))
        try prepare()

        LocalModelInstaller.removeUnusedPreparedModels()
        XCTAssertTrue(fileManager.fileExists(atPath: cache.path), "a downloaded model still uses its prepared copy")

        // What `LocalModelStore.deleteModel` runs. The store itself is a
        // singleton whose launch cleanup could reach the real folder once
        // the override is gone.
        try LocalModelInstaller.removeAll(manifest)
        XCTAssertFalse(fileManager.fileExists(atPath: manifest.rootDirectory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: cache.path))

        try prepare()
        LocalModelInstaller.removeUnusedPreparedModels()
        XCTAssertFalse(fileManager.fileExists(atPath: cache.path))
    }
}
