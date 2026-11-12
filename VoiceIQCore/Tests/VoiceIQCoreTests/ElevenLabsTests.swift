import XCTest
@testable import VoiceIQCore

/// ElevenLabs Scribe v3: what a call costs, which formatted text is kept,
/// how spoken languages are sent, and a used-up balance.
final class ElevenLabsTests: XCTestCase {
    func testPricesAndEditGate() {
        let batch = ElevenLabs.usage(model: "scribe_v3", seconds: 3600, keyterms: true, editedTurns: 1)!
        XCTAssertEqual(batch.reportedCostUSD!, 0.20 + 0.05 + 0.07, accuracy: 1e-9)
        // Editing bills at least 10 s.
        let short = ElevenLabs.usage(model: "scribe_v3", seconds: 2, keyterms: false, editedTurns: 1)!
        XCTAssertEqual(short.reportedCostUSD!, 2 * 0.20 / 3600 + 10 * 0.07 / 3600, accuracy: 1e-12)
        XCTAssertEqual(PriceBook.perMinutePrice(for: "scribe_v3")!, 0.20 / 60, accuracy: 1e-12)
        XCTAssertEqual(PriceBook.perMinutePrice(for: "scribe_v2_realtime")!, 0.22 / 60, accuracy: 1e-12)
        // Live: $0.22/h, keyterms $0.08/h. Batch redaction: 30% of $0.20.
        let live = ElevenLabs.usage(model: LiveMeetingSession.model, seconds: 3600, keyterms: true, editedTurns: 0)!
        XCTAssertEqual(live.reportedCostUSD!, 0.22 + 0.08, accuracy: 1e-9)
        let redacted = ElevenLabs.usage(model: "scribe_v3", seconds: 3600, keyterms: false, editedTurns: 0, redacted: true)!
        XCTAssertEqual(redacted.reportedCostUSD!, 0.20 + 0.06, accuracy: 1e-9)

        XCTAssertEqual(ElevenLabs.editedText(["edited_transcript": ["kind": "transcript", "text": "A.", "edited_text": "A."]]), "A.")
        XCTAssertNil(ElevenLabs.editedText(["edited_transcript": ["kind": "error", "error_type": "edit_failed"]]))
        XCTAssertEqual(ElevenLabs.accepted(edit: nil, original: "x"), "x")
        XCTAssertEqual(ElevenLabs.accepted(edit: "meet at 3:30 pm on Friday.", original: "meet at three thirty pm on friday"), "meet at 3:30 pm on Friday.")
        // An edit that answers instead of formatting keeps the original.
        XCTAssertEqual(ElevenLabs.accepted(edit: "Sure! The capital of France is Paris, a city known for its art and food.",
                                           original: "what is the capital of france"), "what is the capital of france")
    }

    /// Real Scribe v3 output for 25 s of a Hindi-English podcast
    /// (2026-11-12): the edit translated Hindi, which `ValidationGate` let
    /// through. Punctuation and English-side changes still pass.
    func testAnEditThatTranslatesIsNotUsed() {
        let raw = "You know over the years I have seen this. 2 सवाल है। तो आपको क्यों लगता है कि divine ने आपको क्यों bless किया है इस creative cloud के साथ?"
        let translated = "Over the years, I have seen this. There are two questions. So, why do you think divine has blessed you with this creative cloud?"
        let partly = "Over the years I have seen this. There are two questions. तो आपको क्यों लगता है कि divine ने आपको क्यों bless किया है इस creative cloud के साथ?"
        let formatted = "You know, over the years, I have seen this. 2 सवाल है। तो, आपको क्यों लगता है कि divine ने आपको क्यों bless किया है इस creative cloud के साथ?"
        XCTAssertEqual(ElevenLabs.accepted(edit: translated, original: raw), raw)
        XCTAssertEqual(ElevenLabs.accepted(edit: partly, original: raw), raw)
        XCTAssertEqual(ElevenLabs.accepted(edit: formatted, original: raw), formatted)
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

    /// The Spoken languages picker: the main language comes first, clearing
    /// it clears the others (Scribe v3 refuses others without a main one), and
    /// codes from the old free-text field read as the list's codes.
    func testSpokenLanguagesPicker() {
        XCTAssertEqual(ScribeLanguage.choosing(main: "hin", in: []), ["hin"])
        XCTAssertEqual(ScribeLanguage.choosing(main: "eng", in: ["hin", "eng", "tam"]), ["eng", "tam"])
        XCTAssertEqual(ScribeLanguage.choosing(main: "", in: ["hin", "eng"]), [])
        XCTAssertEqual(ScribeLanguage.toggling("eng", in: ["hin"]), ["hin", "eng"])
        XCTAssertEqual(ScribeLanguage.toggling("eng", in: ["hin", "eng", "tam"]), ["hin", "tam"])
        XCTAssertEqual(ScribeLanguage.toggling("hin", in: ["hin", "eng"]), ["hin", "eng"])
        XCTAssertEqual(ScribeLanguage.toggling("eng", in: []), [])
        XCTAssertEqual(ScribeLanguage.names(["hin", "eng"].dropFirst(), none: "None"), "English")

        let saved = UserDefaults.standard.object(forKey: "spokenLanguages")
        defer { UserDefaults.standard.set(saved, forKey: "spokenLanguages") }
        UserDefaults.standard.set(["hi", "en", "xx", "tam"], forKey: "spokenLanguages")
        XCTAssertEqual(SettingsStore().spokenLanguages, ["hin", "eng", "tam"])
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

private final class NoTransport: LiveTransport, @unchecked Sendable {
    func connect() async throws {}
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { throw LiveError.aborted }
    func close() {}
}
