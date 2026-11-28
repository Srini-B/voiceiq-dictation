import XCTest
@testable import VoiceIQCore

/// The AssemblyAI transport's reading of the gateway's refusals.
final class AssemblyAIClientTests: XCTestCase {
    /// An account without an LLM Gateway balance gets a 400 that names the
    /// model; it must read as no balance, so the dictation goes in tidied
    /// with the balance notice instead of failing as a bad request.
    func testGatewayRefusalWithoutBalanceIsNoBalance() async throws {
        let body = #"{"metadata":{"errors":["Your account does not have access to this LLM Gateway model"]},"message":"invalid request body","code":400}"#
        let server = try ScriptedServer(status: 400, reply: body)
        defer { server.stop() }
        let client = AssemblyAIClient(apiKey: { "test" })

        do {
            _ = try await client.send(url: server.url.appendingPathComponent("v1/chat/completions"), body: Data("{}".utf8),
                                      deadline: 10, modelLabel: "gpt-6-luna", stage: .cleanup)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .noBalance)
        }
        XCTAssertEqual(server.requests.first?.headers["authorization"], "test")
    }
}
