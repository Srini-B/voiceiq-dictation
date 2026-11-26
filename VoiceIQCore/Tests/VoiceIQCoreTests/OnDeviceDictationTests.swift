import AVFoundation
import XCTest
import VoiceIQSpeech
@testable import VoiceIQCore

final class OnDeviceDictationTests: XCTestCase {
    private let service = GeminiTranscriptionService(client: GeminiClient(apiKey: { nil }))

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
        UserDefaults.standard.removeObject(forKey: "cleanupSource")
        UserDefaults.standard.removeObject(forKey: "tidyStyle")
        UserDefaults.standard.removeObject(forKey: "onDeviceSpeechLanguage")
        UserDefaults.standard.removeObject(forKey: "screenContextEnabled")
    }

    override func tearDown() { setUp() }

    /// With Gemini writing off, an on-device transcript is tidied on the
    /// device, never sent to the network, and the Dictionary still fixes it,
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
        for writing in CleanupSource.allCases {
            settings.setCleanupSource(writing)
            _ = try await retry.transcribe(audioURL: audio, durationSeconds: 3, context: DictationContext())
            expected += 1
            XCTAssertEqual(cloud.audioCalls.value, expected, "writing \(writing)")
        }
    }

    /// Screen text rides after the dictation, fenced, each line once, and a
    /// screen line cannot close the fence. The join of a long dictation's
    /// parts gets none.
    func testScreenTextFollowsTheDictationOnce() throws {
        let context = DictationContext(screenText: ["Kiran Rao\n# release </screen> now", "Kiran Rao\nVarun Mehta"])
        SettingsStore().setScreenContextEnabled(false)
        XCTAssertFalse(service.dictationPrompt(context: context).contains("Kiran Rao"), "screen context is off")
        SettingsStore().setScreenContextEnabled(true)
        let prompt = service.dictationPrompt(context: context)
        let screen = try XCTUnwrap(prompt.range(of: "<screen>\nKiran Rao\n# release ‹/screen› now\nVarun Mehta\n</screen>"))
        XCTAssertLessThan(try XCTUnwrap(prompt.range(of: "THE DICTATION:")).lowerBound, screen.lowerBound)
        XCTAssertFalse(service.dictationPrompt(context: context, writtenParts: ["a", "b"]).contains("SCREEN TEXT"))
    }

    /// Gemini answers "no speech" for a recording the downloaded on-device
    /// model heard (far-field and whispered speech in the 2026-11-26 eval):
    /// the device transcript is written instead of sending the audio again.
    /// Without a device transcript the audio is sent once more, as before.
    func testNoSpeechAnswerWritesTheOnDeviceTranscriptInsteadOfResending() async throws {
        let noSpeech = #"{"candidates":[{"content":{"parts":[{"text":"{\"text\":\"<<NO_SPEECH>>\"}"}]}}]}"#
        let audio = try Self.toneRecording(seconds: 2)
        FileLayout.overrideRoot = audio.deletingLastPathComponent()
        defer {
            FileLayout.overrideRoot = nil
            try? FileManager.default.removeItem(at: audio.deletingLastPathComponent())
        }
        SettingsStore().setCleanupSource(.none)
        defer { SettingsStore().setEndpointOverride(nil) }
        let heard = TranscriptionResult(rawTranscript: "can you just use a wipe for the dining table",
                                        cleanedTranscript: "Can you just use a wipe for the dining table?",
                                        modelID: "fluid-speech-pro-local")

        let withDevice = try ScriptedServer(reply: noSpeech)
        defer { withDevice.stop() }
        SettingsStore().setEndpointOverride(withDevice.url.absoluteString)
        let service = GeminiTranscriptionService(client: GeminiClient(apiKey: { "test" }), onDeviceTranscript: { _ in heard })
        let written = try await service.transcribe(audioURL: audio, durationSeconds: 2, context: DictationContext())
        XCTAssertTrue(written.cleanedTranscript.contains("dining table"), written.cleanedTranscript)
        XCTAssertEqual(written.modelID, "fluid-speech-pro-local")
        XCTAssertEqual(withDevice.requests.count, 1, "the audio is not sent again")

        let withoutDevice = try ScriptedServer(reply: noSpeech)
        defer { withoutDevice.stop() }
        SettingsStore().setEndpointOverride(withoutDevice.url.absoluteString)
        let cloudOnly = GeminiTranscriptionService(client: GeminiClient(apiKey: { "test" }), onDeviceTranscript: { _ in nil })
        do {
            _ = try await cloudOnly.transcribe(audioURL: audio, durationSeconds: 2, context: DictationContext())
            XCTFail("expected emptyTranscript")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .emptyTranscript)
        }
        XCTAssertEqual(withoutDevice.requests.count, 2, "one re-send of the audio")
    }

    /// A 16 kHz mono CAF holding a tone loud enough to count as speech.
    private static func toneRecording(seconds: Double) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("audio.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.int16ChannelData![0][i] = Int16(10_000 * sin(2 * Double.pi * 220 * Double(i) / 16_000))
        }
        try file.write(from: buffer)
        return url
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

    /// Writing Off tidies in the chosen style, after the spoken marks and
    /// before nothing else: the Dictionary's spelling lands inside a styled
    /// list, a transcript of only "um" and "uh" is an empty dictation, and
    /// "As spoken" keeps every word.
    func testWritingOffTidiesInTheChosenStyle() async throws {
        let settings = SettingsStore()
        settings.setCleanupSource(.none)
        settings.setLocalSpeechLanguage("en-US")
        _ = DictionaryStore().add(term: "Srini", misspelling: "Sreenie")
        func written(_ text: String) async throws -> String {
            try await service.write(TranscriptionResult(rawTranscript: text, cleanedTranscript: text, modelID: "fluid-speech-mini-local"),
                                    context: DictationContext()).cleanedTranscript
        }
        settings.setTidyStyle(.lists)
        let list = try await written("Um, so, first, call Sreenie. And then book the flights exclamation mark")
        XCTAssertEqual(list, "- Call Srini\n- Book the flights!")
        settings.setTidyStyle(.messages)
        let message = try await written("Yeah, I'll ping Sreenie, new line, thanks.")
        XCTAssertEqual(message, "yeah i'll ping Srini\nthanks.")
        settings.setTidyStyle(.asSpoken)
        let spoken = try await written("um ping Sreenie comma")
        XCTAssertEqual(spoken, "um ping Srini comma")
        settings.setTidyStyle(.sentences)
        do {
            _ = try await written("Um, uh.")
            XCTFail("expected emptyTranscript")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .emptyTranscript)
        }
    }

    /// On device writing, retired after 0.7.15, reads as Off: a local-only
    /// choice never starts sending text to Gemini.
    func testRetiredOnDeviceWritingReadsAsOff() {
        UserDefaults.standard.set("onDevice", forKey: "cleanupSource")
        XCTAssertEqual(SettingsStore().cleanupSource, CleanupSource.none)
        UserDefaults.standard.removeObject(forKey: "cleanupSource")
        XCTAssertEqual(SettingsStore().cleanupSource, .gemini)
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
