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
        // Live: $0.22/h, keyterms $0.08/h. Redaction: 30% of $0.20 batch, of $0.22 live.
        let live = ElevenLabs.usage(model: LiveMeetingSession.model, seconds: 3600, keyterms: true, editedTurns: 0)!
        XCTAssertEqual(live.reportedCostUSD!, 0.22 + 0.08, accuracy: 1e-9)
        let redacted = ElevenLabs.usage(model: "scribe_v3", seconds: 3600, keyterms: false, editedTurns: 0, redacted: true)!
        XCTAssertEqual(redacted.reportedCostUSD!, 0.20 + 0.06, accuracy: 1e-9)
        let liveRedacted = ElevenLabs.usage(model: LiveMeetingSession.model, seconds: 3600, keyterms: false, editedTurns: 0, redacted: true)!
        XCTAssertEqual(liveRedacted.reportedCostUSD!, 0.22 * 1.3, accuracy: 1e-9)

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
    /// The edit may only format what was said. The transcript and the four
    /// remarks are real Scribe v3 output for one 8 s English clip (every edit
    /// of it added one); the formats are real edits or ordinary formatting,
    /// including Japanese punctuation and Tamil mixed into English.
    func testAnEditThatAddsARemarkIsNotUsed() {
        let heard = "Can you check the build logs on the server? The deploy failed again last night, and I think it's the same certificate problem we saw on Monday."
        for remark in ["(This is a single paragraph.)", "(This is a separate paragraph.)", "It's Monday.", "It's a Monday."] {
            XCTAssertEqual(ElevenLabs.accepted(edit: "\(heard) \(remark)", original: heard), heard, remark)
        }
        let formats = [
            ("Increase the build number and version number and-", "Increase the build number and version number, and—"),
            ("MacBook so that I can test out", "MacBook. So that I can test out."),
            ("um so the uh plan is to run ten kilometers on saturday", "So the plan is to run 10 km on Saturday."),
            ("we should pick a color for the logo", "We should pick a colour for the logo."),
            ("ナウミさんまた明日", "ナウミさん、また明日。"),
            ("The meeting is at three. ஆனா இன்னைக்கு கொஞ்சம் லேட் ஆகும். So please wait for me",
             "The meeting is at 3:00. ஆனா இன்னைக்கு கொஞ்சம் லேட் ஆகும். So, please wait for me."),
        ]
        for (raw, edit) in formats { XCTAssertEqual(ElevenLabs.accepted(edit: edit, original: raw), edit, raw) }
    }

    /// A number the edit writes must have been said, as digits or as words
    /// that read as it; one it made up sends the transcript on as heard.
    func testAnEditThatAddsANumberIsNotUsed() {
        let heard = "Please send the invoice to accounting today."
        XCTAssertEqual(ElevenLabs.accepted(edit: "Please send the invoice 99999 to accounting today.", original: heard), heard)
        XCTAssertEqual(ElevenLabs.accepted(edit: "Call me at 3:40.", original: "call me at three thirty"), "call me at three thirty")
        // Digits of any script count, and a number said once is written once.
        XCTAssertEqual(ElevenLabs.accepted(edit: "Please send the invoice ٩٩٩٩٩ to accounting today.", original: heard), heard)
        XCTAssertEqual(ElevenLabs.accepted(edit: "Please send the invoice Ⅷ to accounting today.", original: heard), heard)
        XCTAssertEqual(ElevenLabs.accepted(edit: "Please send the invoice 25Ⅷ to accounting today.",
                                           original: "Please send the invoice 25 to accounting today."),
                       "Please send the invoice 25 to accounting today.")
        XCTAssertEqual(ElevenLabs.accepted(edit: "Pay invoice 25 25 today.", original: "pay invoice 25 today"), "pay invoice 25 today")
        // Digits must stand for the whole spoken number, not part of it.
        for (raw, edit) in [("Pay one hundred dollars", "Pay 1 dollar."), ("Pay twenty five dollars", "Pay 20 dollars."),
                            ("Pay 1.50 dollars today", "Pay 150 dollars today."),
                            ("Pay three point five dollars today", "Pay 35 dollars today."),
                            ("The temperature is -25 degrees today", "The temperature is 25 degrees today."),
                            ("The temperature is 25 degrees today", "The temperature is -25 degrees today."),
                            ("Take five milligrams daily", "Take 5kg daily."),
                            ("Pay twenty five dollars today", "Pay 25bitcoin today."),
                            ("Pay Alice twenty five dollars and Bob fifty dollars", "Pay Alice 50 dollars and Bob 25 dollars."),
                            ("Pay twenty five dollars today", "Pay 205 dollars today."),
                            ("Pay two hundred dollars today", "Pay 2100 dollars today."),
                            ("Wait 1:30 minutes before starting", "Wait 130 minutes before starting."),
                            ("Wait 130 minutes before starting", "Wait 1:30 minutes before starting."),
                            ("Wait one thirty minutes before starting", "Wait 13:0 minutes before starting."),
                            ("Take 1-2 tablets daily with water", "Take 12 tablets daily with water.")] {
            XCTAssertEqual(ElevenLabs.accepted(edit: edit, original: raw), raw, edit)
        }
        XCTAssertEqual(ElevenLabs.accepted(edit: "Please send one 1 invoice to accounting today.",
                                           original: "Please send one invoice to accounting today."),
                       "Please send one invoice to accounting today.")
        let formats = [
            ("it costs twenty five dollars", "It costs $25."),
            ("call me at three thirty", "Call me at 3:30."),
            ("born in nineteen ninety nine", "Born in 1999."),
            ("the rate is three point five percent", "The rate is 3.5%."),
            ("my number is five five five one two three four", "My number is 555-1234."),
            ("we sold fifteen hundred units in two thousand twenty six", "We sold 1,500 units in 2026."),
            ("the twenty first floor", "The 21st floor."),
            ("one more thing at three thirty", "One more thing at 3:30."),
            ("it was minus five outside", "It was -5 outside."),
            ("run ten kilometers", "Run 10km."),
            ("Pay Alice twenty five dollars and Bob fifty dollars", "Pay Alice $25 and Bob $50."),
        ]
        for (raw, edit) in formats { XCTAssertEqual(ElevenLabs.accepted(edit: edit, original: raw), edit, raw) }
    }

    /// The edit keeps every word said, in order, apart from fillers, a word
    /// said twice in a row, and words it writes as digits or as the symbol
    /// they name.
    func testAnEditThatLeavesOutWordsIsNotUsed() {
        for (raw, edit) in [("Do not delete the backup today", "Delete the backup today."),
                            ("Send it to Alice and Bob today", "Send it to Alice today."),
                            ("Pay twenty five dollars to Bob", "Pay dollars to Bob."),
                            ("The test came back negative today", "The test came back today."),
                            ("Alice owes Bob money today", "Bob owes Alice money today."),
                            ("Transfer 25 dollars to Alice today", "Transfer €25 to Alice today."),
                            ("Transfer 25 dollars to Alice today", "Transfer 25 to Alice today."),
                            ("Give Alice 25 dollars and Bob 50 euros today", "Give Alice €25 and Bob $50 today."),
                            ("Take ½ tablet daily with water", "Take tablet daily with water."),
                            ("We hired five engineers and fired contractors", "We hired engineers and fired 5 contractors."),
                            ("Take ½ tablet in the morning and ¼ tablet at night", "Take ¼ tablet in the morning and ½ tablet at night.")] {
            XCTAssertEqual(ElevenLabs.accepted(edit: edit, original: raw), raw, edit)
        }
        let formats = [
            ("I I think we should go", "I think we should go."),
            ("um it's a hundred dollars", "It's $100."),
            ("meet at three o'clock", "Meet at 3:00."),
            ("email john at example dot com", "Email john@example.com."),
            ("pay one hundred and five dollars", "Pay $105."),
            ("Give Alice 25 dollars and Bob 50 euros today", "Give Alice $25 and Bob €50 today."),
            ("It costs $25, not 25 euros", "It costs $25, not €25."),
            ("It has 25,000 rupees of data in it", "It has ₹25,000 of data in it."),
            ("take ½ tablet in the morning and ¼ tablet at night", "Take ½ tablet in the morning and ¼ tablet at night."),
        ]
        for (raw, edit) in formats { XCTAssertEqual(ElevenLabs.accepted(edit: edit, original: raw), edit, raw) }
    }

    /// A word the edit changes is only respelled ("colour") or a unit
    /// abbreviated ("km"), a question stays a question, and a leading
    /// decimal point counts.
    func testAnEditThatChangesAWordIsNotUsed() {
        for (raw, edit) in [("Increase the limit to five hundred", "Decrease the limit to 500."),
                            ("The meeting is in June", "The meeting is in July."),
                            ("The patient is able to walk", "The patient is unable to walk."),
                            ("The patient is hypertensive today", "The patient is hypotensive today."),
                            ("The tank was filled yesterday", "The tank was filed yesterday."),
                            ("Do not delete it", "Do note delete it."),
                            ("Ship five kilograms of rice", "Ship 5 km of rice."),
                            ("It weighs 5 pounds", "It weighs £5."),
                            ("Are you coming tonight?", "Are you coming tonight."),
                            ("Take .5 milligrams daily with water", "Take 5 milligrams daily with water.")] {
            XCTAssertEqual(ElevenLabs.accepted(edit: edit, original: raw), raw, edit)
        }
        let formats = [
            ("meet me at the center", "Meet me at the centre."),
            ("send me your resume", "Send me your résumé."),
            ("please organize the files", "Please organise the files."),
            ("we traveled to the theater", "We travelled to the theatre."),
            ("take two to three tablets", "Take 2-3 tablets."),
            ("take point five milligrams", "Take 0.5 mg."),
            ("is it ready", "Is it ready?"),
            ("And increase. the version number", "And increase the version number"),
        ]
        for (raw, edit) in formats { XCTAssertEqual(ElevenLabs.accepted(edit: edit, original: raw), edit, raw) }
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
