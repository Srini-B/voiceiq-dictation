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
        XCTAssertTrue(server.requests.first?.headers["user-agent"]?.hasPrefix("VoiceiQ/") == true)
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

    /// Only a status that means the key is wrong blocks onboarding; a moved
    /// endpoint, a captive portal or a proxy lets it continue.
    func testOnlyKeyErrorsRejectAKey() {
        for status in [400, 401, 403, 422] {
            XCTAssertEqual(AssemblyAIClient.keyCheck(status: status, body: Data(#"{"error":"Invalid API key"}"#.utf8)),
                           .rejected("Invalid API key"), "\(status)")
        }
        for status in [404, 405, 407, 410, 429, 451, 500, 503] {
            XCTAssertEqual(AssemblyAIClient.keyCheck(status: status, body: Data()), .unreachable, "\(status)")
        }
        XCTAssertEqual(AssemblyAIClient.keyCheck(status: 200, body: Data()), .valid)
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
