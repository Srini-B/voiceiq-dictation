import XCTest
@testable import VoiceIQCore

/// The one-call dictation request and the meeting chat request, against a
/// local server that records what was sent.
final class GeminiRequestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiRequestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileLayout.overrideRoot = root
    }

    override func tearDownWithError() throws {
        FileLayout.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// generateContent's envelope around one text part.
    private static func reply(_ text: String) -> String {
        let part = try! JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]])
        return String(decoding: part, as: UTF8.self)
    }

    private func dictate(replying text: String, audio: Data = Data([1, 2, 3])) async throws -> (String, ScriptedServer.Request) {
        let server = try ScriptedServer(reply: Self.reply(text))
        defer { server.stop() }
        let result = try await GeminiClient(apiKey: { "test" })
            .dictate(prompt: "RULES", audio: audio, model: "gemini-3.8-flash", endpoint: server.url, deadline: 10)
        return (result, try XCTUnwrap(server.requests.last))
    }

    func testDictationSendsThePromptThenTheAudioAndReadsTheTextField() async throws {
        let audio = Data("flac bytes".utf8)
        let (text, request) = try await dictate(replying: #"{"text":"Let's meet at 3 on Thursday."}"#, audio: audio)
        XCTAssertEqual(text, "Let's meet at 3 on Thursday.")

        let body = try XCTUnwrap(request.json)
        let parts = try XCTUnwrap((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "RULES")
        let inline = try XCTUnwrap(parts.last?["inline_data"] as? [String: Any])
        XCTAssertEqual(inline["mime_type"] as? String, "audio/flac")
        XCTAssertEqual(inline["data"] as? String, audio.base64EncodedString())
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertEqual((config["responseJsonSchema"] as? [String: Any])?["required"] as? [String], ["text"])
    }

    func testNoSpeechTokenBecomesEmptyText() async throws {
        let (text, _) = try await dictate(replying: #"{"text":"\#(PromptV1.noSpeechToken)"}"#)
        XCTAssertEqual(text, "", "the coordinator judges silence; the token must never be typed")
    }

    /// With audio attached the model sometimes writes its working before the
    /// result. That text must never be pasted; the request is retried.
    func testWorkingInsteadOfTheJSONAnswerIsRetryableNotPasted() async throws {
        do {
            _ = try await dictate(replying: "Let me re-listen at 0:12. Draft: Let's meet at 3.")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .network("malformed_answer"))
        }
    }

    func testMeetingChatReplaysEarlierTurnsInOrder() async throws {
        let server = try ScriptedServer(reply: Self.reply("Friday."))
        defer { server.stop() }
        let answer = try await GeminiClient(apiKey: { "test" }).chat(
            system: MeetingChat.system(meeting: "**Rohan:** I'll own the launch."),
            turns: [("Who owns the launch?", "Rohan.")], question: "By when?",
            model: "gemini-3.8-flash", endpoint: server.url, deadline: 10, stage: .meetingChat
        )
        XCTAssertEqual(answer, "Friday.")

        let body = try XCTUnwrap(server.requests.last?.json)
        XCTAssertNil(body["tools"])
        let system = (body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
        XCTAssertTrue((system?.first?["text"] as? String ?? "").contains("I'll own the launch."))
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
        XCTAssertEqual(contents.map { (($0["parts"] as? [[String: Any]])?.first?["text"] as? String) },
                       ["Who owns the launch?", "Rohan.", "By when?"])
    }

    func testSpellingFollowsTheRegion() {
        XCTAssertEqual(SpellingVariant.forRegion("IN", language: "en"), .englishIN)
        XCTAssertEqual(SpellingVariant.forRegion("GB", language: "en"), .englishUK)
        XCTAssertEqual(SpellingVariant.forRegion("US", language: "en"), .englishUS)
        XCTAssertEqual(SpellingVariant.forRegion("NZ", language: "en"), .englishAU)
        XCTAssertEqual(SpellingVariant.forRegion("CA", language: "en"), .englishCA)
        XCTAssertEqual(SpellingVariant.forRegion("CA", language: "fr"), .frenchCanada)
        XCTAssertEqual(SpellingVariant.forRegion("MX", language: "es"), .spanishLatinAmerica)
        XCTAssertEqual(SpellingVariant.forRegion("TW", language: "zh"), .chineseTraditional)
        XCTAssertEqual(SpellingVariant.forRegion("DE", language: "en"), .automatic)
        XCTAssertEqual(SpellingVariant.forRegion(nil, language: "en"), .automatic)
    }
}

final class InteractionsEnvelopeTests: XCTestCase {

    func testFailedWithSafetyDetailMapsToSafetyBlocked() {
        let error = GeminiClient.mapInteractionStatus(
            "failed", json: ["error": ["message": "Response blocked by safety filters"]]
        )
        XCTAssertEqual(error, .safetyBlocked)
    }

    func testFailedWithoutSafetyDetailIsRetryable() {
        let error = GeminiClient.mapInteractionStatus("failed", json: [:])
        guard case .network = error else {
            return XCTFail("a bare failure should stay retryable, got \(error)")
        }
    }

    /// The two endpoints do not share an error envelope: interactions
    /// array-wraps auth errors. Casting straight to [String: Any] yields nil and
    /// the user sees "http_400" instead of "API key not valid".
    func testErrorMessageParsesArrayWrappedEnvelope() {
        let wrapped = Data(#"[{"error":{"code":400,"message":"API key not valid."}}]"#.utf8)
        XCTAssertEqual(GeminiClient.errorMessage(from: wrapped), "API key not valid.")

        let plain = Data(#"{"error":{"code":400,"message":"API key not valid."}}"#.utf8)
        XCTAssertEqual(GeminiClient.errorMessage(from: plain), "API key not valid.")
    }

    /// interactions reports `code` as a String ("not_found") where
    /// generateContent reports an Int. We only read `message`, so this is a
    /// regression guard on that staying true.
    func testErrorMessageSurvivesStringCode() {
        let body = Data(#"{"error":{"code":"not_found","message":"Model 'x' not found."}}"#.utf8)
        XCTAssertEqual(GeminiClient.errorMessage(from: body), "Model 'x' not found.")
    }
}
