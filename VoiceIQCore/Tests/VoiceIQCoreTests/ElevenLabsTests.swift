import XCTest
@testable import VoiceIQCore

/// ElevenLabs Scribe v3: what a call costs, the live dictation stream,
/// how spoken languages are sent, and a used-up balance.
final class ElevenLabsTests: XCTestCase {
    /// Scribe v3 Live for dictation: the hotkey commits the turn, and the
    /// committed text is the turn's final.
    func testLiveDictationDialect() throws {
        let dialect = ElevenLabsLiveDialect(smart: true, vocabulary: ["VoiceiQ"], languages: ["eng"])
        let query = try XCTUnwrap(URLComponents(url: dialect.socketURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "commit_strategy", value: "manual")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "no_verbatim", value: "true")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "keyterms", value: "VoiceiQ")))
        XCTAssertFalse(query.contains { $0.name == "diarize" })

        let end = try XCTUnwrap(JSONSerialization.jsonObject(with: dialect.activityEndFrame()) as? [String: Any])
        XCTAssertEqual(end["commit"] as? Bool, true)
        XCTAssertEqual(end["audio_base_64"] as? String, "")
        let audio = try XCTUnwrap(JSONSerialization.jsonObject(with: dialect.audioFrame(Data([1, 0]))) as? [String: Any])
        XCTAssertEqual(audio["commit"] as? Bool, false)
        XCTAssertEqual(audio["audio_base_64"] as? String, Data([1, 0]).base64EncodedString())

        func events(_ json: String) -> [LiveEvent] { dialect.decode(Data(json.utf8)) }
        XCTAssertEqual(events(#"{"message_type":"session_started","session_id":"x"}"#), [.setupComplete])
        XCTAssertEqual(events(#"{"message_type":"partial_transcript","text":"Hey can"}"#), [.partial("Hey can")])
        XCTAssertEqual(events(#"{"message_type":"committed_transcript","text":" Hey, can you? "}"#),
                       [.final("Hey, can you?"), .turnComplete])
        XCTAssertEqual(events(#"{"message_type":"committed_transcript","text":""}"#), [.turnComplete])
        guard case .failed(let failure) = events(#"{"message_type":"auth_error","error":"bad key"}"#).first else {
            return XCTFail("auth_error must fail the session")
        }
        XCTAssertEqual(failure.status, 401)
        XCTAssertEqual(events(#"{"message_type":"something_new"}"#), [])
    }

    func testPrices() {
        let batch = ElevenLabs.usage(model: "scribe_v3", seconds: 3600, keyterms: true)!
        XCTAssertEqual(batch.reportedCostUSD!, 0.20 + 0.05, accuracy: 1e-9)
        XCTAssertEqual(PriceBook.perMinutePrice(for: "scribe_v3")!, 0.20 / 60, accuracy: 1e-12)
        XCTAssertEqual(PriceBook.perMinutePrice(for: "scribe_v2_realtime")!, 0.22 / 60, accuracy: 1e-12)
        // Live: $0.22/h, keyterms $0.08/h. Redaction: 30% of $0.20 batch, of $0.22 live.
        let live = ElevenLabs.usage(model: LiveMeetingSession.model, seconds: 3600, keyterms: true)!
        XCTAssertEqual(live.reportedCostUSD!, 0.22 + 0.08, accuracy: 1e-9)
        let redacted = ElevenLabs.usage(model: "scribe_v3", seconds: 3600, keyterms: false, redacted: true)!
        XCTAssertEqual(redacted.reportedCostUSD!, 0.20 + 0.06, accuracy: 1e-9)
        let liveRedacted = ElevenLabs.usage(model: LiveMeetingSession.model, seconds: 3600, keyterms: false, redacted: true)!
        XCTAssertEqual(liveRedacted.reportedCostUSD!, 0.22 * 1.3, accuracy: 1e-9)
    }

    /// Redacted live text keeps each heard word's speaker and time: in
    /// Japanese, written without spaces, and after placeholders in a row.
    func testRedactedWordsKeepTheirSpeakers() {
        func words(_ list: [(String, String, Double)]) -> [DiarizedWord] {
            list.map { DiarizedWord(text: $0.0, speaker: $0.1, start: $0.2, end: $0.2 + 0.5) }
        }
        func shown(_ redacted: [DiarizedWord]) -> [String] { redacted.map { "\($0.speaker ?? "?") \($0.start ?? -1): \($0.text)" } }

        XCTAssertEqual(shown(ElevenLabs.redacting(words([("はい。", "a", 0), ("いいえ。", "b", 1)]), as: "はい。いいえ。")),
                       ["a 0.0: はい。", "b 1.0: いいえ。"])
        XCTAssertEqual(shown(ElevenLabs.redacting(words([("番号は", "a", 0), ("4111", "a", 1), ("です。", "a", 2), ("了解。", "b", 3)]),
                                                  as: "番号は{CREDIT_CARD}です。了解。")),
                       ["a 0.0: 番号は", "a 1.0: {CREDIT_CARD}", "a 2.0: です。", "b 3.0: 了解。"])
        XCTAssertEqual(shown(ElevenLabs.redacting(words([("4111-1111", "a", 0), ("hunter2", "a", 1), ("Thanks.", "b", 2), ("Next.", "b", 3)]),
                                                  as: "{CREDIT_CARD} {PASSWORD} Thanks. Next.")),
                       ["a 0.0: {CREDIT_CARD}", "a 1.0: {PASSWORD}", "b 2.0: Thanks.", "b 3.0: Next."])
    }

    /// Secondary codes without a `language_code` answer 500 (measured
    /// 2026-11-12), so the first spoken language always goes as the main one.
    func testSpokenLanguagesAlwaysNameAMainLanguage() {
        func fields(_ codes: [String]) -> [String] {
            var form = MultipartForm()
            form.languages(codes)
            let body = String(decoding: form.body, as: UTF8.self)
            return body.components(separatedBy: "name=\"").dropFirst().map { part in
                let name = part.prefix { $0 != "\"" }
                let value = part.components(separatedBy: "\r\n\r\n")[1].components(separatedBy: "\r\n")[0]
                return "\(name)=\(value)"
            }
        }
        XCTAssertEqual(fields([]), [])
        XCTAssertEqual(fields(["ta"]), ["language_code=ta"])
        XCTAssertEqual(fields(["en", "hi", "ta"]), ["language_code=en", "secondary_language_codes=hi", "secondary_language_codes=ta"])
    }

    /// The live meeting socket: turn prediction, diarization, no fillers;
    /// several spoken languages switch on multilingual mode instead of
    /// fixing one; a keyterm cannot split the query.
    func testLiveMeetingSocketAsksForTurnsSpeakersAndLanguages() throws {
        func query(_ languages: [String]) throws -> [String] {
            let url = LiveMeetingSession.socketURL(keyterms: ["C++ & Go"], languages: languages)
            return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                .map { "\($0.name)=\($0.value ?? "")" }
        }
        let common = ["model_id=scribe_v3_live", "audio_format=pcm_16000", "commit_strategy=turn_prediction",
                      "diarize=true", "no_verbatim=true"]
        XCTAssertEqual(try query([]), common + ["keyterms=C++ & Go"])
        XCTAssertEqual(try query(["hi"]), common + ["language_code=hi", "keyterms=C++ & Go"])
        XCTAssertEqual(try query(["en", "hi"]), common + ["secondary_languages=en", "secondary_languages=hi",
                                                          "multilang_mode=true", "keyterms=C++ & Go"])
        let redacting = try XCTUnwrap(URLComponents(url: LiveMeetingSession.socketURL(keyterms: [], languages: [], redacts: true),
                                                    resolvingAgainstBaseURL: false)?.queryItems)
            .map { "\($0.name)=\($0.value ?? "")" }
        XCTAssertEqual(Array(redacting.dropFirst(common.count)),
                       ElevenLabs.redactedEntities.map { "entity_redaction=\($0)" } + ["entity_redaction_mode=entity_type"])
    }

    /// A redacting live session never shows a heard card number: the partial
    /// is not shown, and a turn waits for its redacted text, which keeps the
    /// speakers of the words it replaced.
    func testRedactingLiveSessionShowsOnlyRedactedTurns() async {
        let shown = Shown()
        let session = LiveMeetingSession(transport: NoTransport(), vocabulary: [], tracks: 1, redacts: true) { shown.add($0) }
        func frame(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        let heard = "My card is 4111 1111 1111 1111. Thanks."
        let words: [[String: Any]] = [("My", "speaker_0", 0.0), ("card", "speaker_0", 0.3), ("is", "speaker_0", 0.6),
                                      ("4111", "speaker_0", 1.0), ("1111", "speaker_0", 1.5), ("1111", "speaker_0", 2.0),
                                      ("1111.", "speaker_0", 2.5), ("Thanks.", "speaker_1", 3.5)]
            .map { ["text": $0.0, "type": "word", "speaker_id": $0.1, "start": $0.2, "end": $0.2 + 0.4] }
        await session.handle(frame(["message_type": "partial_transcript", "text": "My card is 4111"]))
        await session.handle(frame(["message_type": "committed_transcript", "segment_index": 0, "text": heard]))
        await session.handle(frame(["message_type": "diarized_transcript", "segment_index": 0, "text": heard, "words": words]))
        XCTAssertTrue(shown.all.isEmpty)
        await session.handle(frame(["message_type": "redacted_transcript", "text": heard,
                                    "redacted_text": "My card is {CREDIT_CARD}. Thanks."]))

        XCTAssertFalse(shown.all.contains { $0.partial.contains("4111") || $0.segments.contains { $0.text.contains("4111") } })
        XCTAssertEqual(shown.all.last?.segments.map { "\($0.speaker) \($0.start ?? -1)-\($0.end ?? -1): \($0.text)" },
                       ["s1 0.0-2.9: My card is {CREDIT_CARD}.", "s2 3.5-3.9: Thanks."])
    }

    /// `speakers_merged` rewrites every earlier use of the merged id, and
    /// merges chain.
    func testLiveSpeakersFollowMerges() async {
        let session = LiveMeetingSession(transport: NoTransport(), vocabulary: [], tracks: 1) { _ in }
        func frame(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func word(_ text: String, _ speaker: String, _ start: Double) -> [String: Any] {
            ["text": text, "type": "word", "speaker_id": speaker, "start": start, "end": start + 0.5]
        }
        await session.handle(frame(["message_type": "diarized_transcript", "segment_index": 0,
                                    "words": [word("a", "speaker_0", 0), word("b", "speaker_1", 1)]]))
        await session.handle(frame(["message_type": "diarized_transcript", "segment_index": 1,
                                    "words": [word("c", "speaker_2", 2), word("d", "speaker_0", 3)]]))
        var speakers = await session.timedWords().map { "\($0.text)=\($0.speaker)" }
        XCTAssertEqual(speakers, ["a=s1", "b=s2", "c=s3", "d=s1"])
        await session.handle(frame(["message_type": "speakers_merged", "from_speaker_id": "speaker_2", "to_speaker_id": "speaker_1"]))
        speakers = await session.timedWords().map { "\($0.text)=\($0.speaker)" }
        XCTAssertEqual(speakers, ["a=s1", "b=s2", "c=s2", "d=s1"])
        await session.handle(frame(["message_type": "speakers_merged", "from_speaker_id": "speaker_1", "to_speaker_id": "speaker_0"]))
        speakers = await session.timedWords().map { "\($0.text)=\($0.speaker)" }
        XCTAssertEqual(speakers, ["a=s1", "b=s1", "c=s1", "d=s1"])
    }

    /// A mic that drops out for 3 s (a device reconnecting) is heard again
    /// once it comes back, not traded against the audio it lost.
    func testLiveMixKeepsTheMicAfterItDropsOut() {
        var mix = LiveCallMix(tracks: 2), out: [[Int16]] = []
        let tick = [Int16](repeating: 0, count: LiveCallMix.chunk)
        func step(mic: Bool) {
            out += mix.push(.system, tick.map { _ in 100 })
            if mic { out += mix.push(.mic, tick.map { _ in 1_000 }) }
        }
        for _ in 0..<5 { step(mic: true) }
        for _ in 0..<30 { step(mic: false) }
        for _ in 0..<20 { step(mic: true) }

        XCTAssertEqual(out.last?.first, 1_100)
        XCTAssertGreaterThanOrEqual(out.count, 45)
    }

    /// The Spoken languages picker: the main language comes first, clearing
    /// it clears the others (Scribe v3 refuses others without a main one), and
    /// codes from the old free-text field read as the list's codes.
    func testSpokenLanguagesPicker() {
        XCTAssertEqual(SpokenLanguage.choosing(main: "hin", in: []), ["hin"])
        XCTAssertEqual(SpokenLanguage.choosing(main: "eng", in: ["hin", "eng", "tam"]), ["eng", "tam"])
        XCTAssertEqual(SpokenLanguage.choosing(main: "", in: ["hin", "eng"]), [])
        XCTAssertEqual(SpokenLanguage.toggling("eng", in: ["hin"]), ["hin", "eng"])
        XCTAssertEqual(SpokenLanguage.toggling("eng", in: ["hin", "eng", "tam"]), ["hin", "tam"])
        XCTAssertEqual(SpokenLanguage.toggling("hin", in: ["hin", "eng"]), ["hin", "eng"])
        XCTAssertEqual(SpokenLanguage.toggling("eng", in: []), [])
        XCTAssertEqual(SpokenLanguage.promoting("jpn", in: ["eng", "tam", "jpn"]), ["jpn", "eng", "tam"])
        XCTAssertEqual(SpokenLanguage.promoting("hin", in: ["eng", "tam"]), ["eng", "tam"])
        XCTAssertEqual(SpokenLanguage.names(["hin", "eng"].dropFirst(), none: "None"), "English")

        let saved = UserDefaults.standard.object(forKey: "spokenLanguages")
        defer { UserDefaults.standard.set(saved, forKey: "spokenLanguages") }
        UserDefaults.standard.set(["hi", "en", "xx", "tam"], forKey: "spokenLanguages")
        XCTAssertEqual(SettingsStore().spokenLanguages, ["hin", "eng", "tam"])
    }

    /// OpenAI gets the spoken languages as two-letter codes, or none when one
    /// has no such code (a partial list would shut that language out), and a
    /// prompt naming each language in English and in itself once there are
    /// several.
    func testOpenAIGetsTheSpokenLanguages() {
        XCTAssertEqual(SpokenLanguage.openAICodes(["eng", "tam", "jpn"]), ["en", "ta", "ja"])
        XCTAssertEqual(SpokenLanguage.openAICodes(["eng", "ceb"]), [])
        XCTAssertEqual(SpokenLanguage.openAICodes([]), [])
        XCTAssertNil(SpokenLanguage.transcriptionPrompt(["eng"]))
        XCTAssertNil(SpokenLanguage.transcriptionPrompt([]))
        XCTAssertEqual(SpokenLanguage.transcriptionPrompt(["eng", "tam", "jpn"]),
                       "Dictation in English, Tamil (தமிழ்) and Japanese (日本語), sometimes switching language mid-sentence.")
    }

    func testUsedUpCreditIsNotABadKey() {
        let quota = GeminiClient.elevenLabsErrorDetail(from: Data(#"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota"}}"#.utf8))
        XCTAssertTrue(GeminiClient.isElevenLabsQuota(quota))
        let bad = GeminiClient.elevenLabsErrorDetail(from: Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8))
        XCTAssertFalse(GeminiClient.isElevenLabsQuota(bad))
        XCTAssertEqual(GeminiClient.errorMessage(from: Data(#"{"detail":[{"loc":["body","keyterms"],"msg":"bad term","type":"value_error"}]}"#.utf8)), "bad term")
        XCTAssertEqual(ElevenLabs.keyterms(["Kubernetes", "kubernetes", "a b c d e f", "<tag>", ""], limit: 100, maxCharacters: 49), ["Kubernetes", "tag"])
    }
}

private final class Shown: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LiveMeetingTranscript] = []
    func add(_ item: LiveMeetingTranscript) { lock.withLock { items.append(item) } }
    var all: [LiveMeetingTranscript] { lock.withLock { items } }
}

private final class NoTransport: LiveTransport, @unchecked Sendable {
    func connect() async throws {}
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { throw LiveError.aborted }
    func close() {}
}
