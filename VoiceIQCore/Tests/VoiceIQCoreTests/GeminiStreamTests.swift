import XCTest
@testable import VoiceIQCore

final class GeminiStreamTests: XCTestCase {
    /// A streamed answer as Gemini sent it (2026-11-26, trimmed): the JSON
    /// answer split across chunks, a last chunk with only a thought
    /// signature, usage on every chunk.
    func testAStreamedAnswerJoinsIntoTheTextAndTheLastUsage() throws {
        let body = #"""
data: {"candidates": [{"content": {"parts": [{"text": "{\"text\": \"I need three things from"}],"role": "model"},"index": 0}],"usageMetadata": {"promptTokenCount": 252,"candidatesTokenCount": 9,"totalTokenCount": 261,"promptTokensDetails": [{"modality": "AUDIO","tokenCount": 229},{"modality": "TEXT","tokenCount": 23}],"serviceTier": "standard"},"modelVersion": "gemini-3.8-flash","responseId": "r"}

data: {"candidates": [{"content": {"parts": [{"text": " you. First, update the readme. Second, fix the flaky login test. Third, bump the version.\"}"}],"role": "model"},"index": 0}],"usageMetadata": {"promptTokenCount": 252,"candidatesTokenCount": 32,"totalTokenCount": 284,"promptTokensDetails": [{"modality": "TEXT","tokenCount": 23},{"modality": "AUDIO","tokenCount": 229}],"serviceTier": "standard"},"modelVersion": "gemini-3.8-flash","responseId": "r"}

data: {"candidates": [{"content": {"parts": [{"text": "","thoughtSignature": "sig"}],"role": "model"},"finishReason": "STOP","index": 0}],"usageMetadata": {"promptTokenCount": 252,"candidatesTokenCount": 32,"totalTokenCount": 284,"promptTokensDetails": [{"modality": "TEXT","tokenCount": 23},{"modality": "AUDIO","tokenCount": 229}],"serviceTier": "standard"},"modelVersion": "gemini-3.8-flash","responseId": "r"}
"""#
        let joined = try XCTUnwrap(GeminiClient.joinedEventStream(Data(body.utf8)))
        let text = try GeminiClient.extractText(from: joined)
        XCTAssertEqual(PromptV1.dictationText(fromJSON: text),
                       "I need three things from you. First, update the readme. Second, fix the flaky login test. Third, bump the version.")
        XCTAssertEqual(TokenUsage.fromGenerateContent(joined)?.totalOut, 32)
    }
}
