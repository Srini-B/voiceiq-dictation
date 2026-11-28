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
        let error = try await refusal(from: server)
        XCTAssertEqual(error, .noBalance)
        XCTAssertEqual(server.requests.first?.headers["authorization"], "test")
    }

    /// The speech API's 400 once the free credit is spent reads as no
    /// balance too, not as a bad request.
    func testSpentCreditIsNoBalance() async throws {
        let body = #"{"error": "Your current account balance is negative. Please top up to continue using the API."}"#
        let server = try ScriptedServer(status: 400, reply: body)
        defer { server.stop() }
        let error = try await refusal(from: server)
        XCTAssertEqual(error, .noBalance)
    }

    private func refusal(from server: ScriptedServer) async throws -> TranscriptionError? {
        let client = AssemblyAIClient(apiKey: { "test" })
        do {
            _ = try await client.send(url: server.url.appendingPathComponent("v2/transcript"), body: Data("{}".utf8),
                                      deadline: 10, modelLabel: "assemblyai-stt-3-7", stage: .cleanup)
            XCTFail("expected a failure")
            return nil
        } catch {
            return error as? TranscriptionError
        }
    }
}
