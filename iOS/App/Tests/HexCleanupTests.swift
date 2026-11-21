import XCTest
@testable import VoiceiQ

/// Hex's cleanup tagger with its real Core ML model, as the app bundles it.
final class HexCleanupTests: XCTestCase {
    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    func testTheTaggerDropsFillersAndKeepsTheContentWords() async throws {
        let spoken = "um I think uh we should ship the build to Priya by 5 on Friday"
        // Loads the model; the budgeted call below then runs as dictation runs it.
        _ = try await Task.detached { try CleanupTagger.shared.clean(spoken) }.value

        let cleaned = await CleanupTagger.shared.clean(spoken, within: CleanupTagger.timeBudget)

        XCTAssertEqual(words(cleaned), ["i", "think", "we", "should", "ship", "the", "build", "to", "priya", "by", "5", "on", "friday"], cleaned)
    }
}
