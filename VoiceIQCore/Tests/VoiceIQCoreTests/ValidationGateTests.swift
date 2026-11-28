import XCTest
@testable import VoiceIQCore

final class ValidationGateTests: XCTestCase {
    func testStripsCodeFences() {
        XCTAssertEqual(ValidationGate.stripArtifacts("```\nHello there.\n```"), "Hello there.")
    }

    func testStripsLabels() {
        XCTAssertEqual(ValidationGate.stripArtifacts("CLEAN: Hello there."), "Hello there.")
        XCTAssertEqual(ValidationGate.stripArtifacts("Transcript: Hello."), "Hello.")
    }

    func testStripsWrappingQuotes() {
        XCTAssertEqual(ValidationGate.stripArtifacts("\"Hello there.\""), "Hello there.")
    }

    func testLeavesInternalQuotesAlone() {
        XCTAssertEqual(ValidationGate.stripArtifacts("She said \"hi\" to me."), "She said \"hi\" to me.")
    }

    /// The writer's one-line email gets the email layout; a message without
    /// both a greeting and a signed sign-off is left as written.
    func testAOneLineEmailIsLaidOut() {
        XCTAssertEqual(EmailLayout.apply("Hello Dr. Kim, I wanted to confirm my appointment at 3. Best, Sam."),
                       "Hello Dr. Kim,\n\nI wanted to confirm my appointment at 3.\n\nBest,\nSam")
        XCTAssertEqual(EmailLayout.apply("Hi Sam, iOS 18 is required. Best, Dana"),
                       "Hi Sam,\n\niOS 18 is required.\n\nBest,\nDana")
        XCTAssertEqual(EmailLayout.apply("Hi Sam, She replied, “Approved.” Thanks, Dana."),
                       "Hi Sam,\n\nShe replied, “Approved.”\n\nThanks,\nDana")
        XCTAssertEqual(EmailLayout.apply("Hi Sam, user_id is null in prod. Thanks, Dana"),
                       "Hi Sam,\n\nuser_id is null in prod.\n\nThanks,\nDana")
        XCTAssertEqual(EmailLayout.apply("Hi Sam, follow-up is ready. Best, Dana"),
                       "Hi Sam,\n\nFollow-up is ready.\n\nBest,\nDana")
        XCTAssertEqual(EmailLayout.apply("Hi Sam, can you check it? Thanks again, Dana"),
                       "Hi Sam,\n\nCan you check it?\n\nThanks again,\nDana")
        let oneLine = "Hi Sam, The release is ready. Thanks, Dana"
        XCTAssertEqual(EmailLayout.apply(oneLine, customRules: "Keep messages in a single paragraph."), oneLine)
        XCTAssertEqual(EmailLayout.apply(oneLine, customRules: "Spell it VoiceiQ."),
                       "Hi Sam,\n\nThe release is ready.\n\nThanks,\nDana")
        let laidOut = "Hi Priya,\n\nCan we move it to net 30?\n\nThanks,\nSrini"
        XCTAssertEqual(EmailLayout.apply(laidOut), laidOut)
        for prose in ["Hey, can you check the logs? Thanks, Ana.", "Hi Sam, Please review the report. Best Regards.",
                      "Hi Sam, Please review the report. Thanks Again.", "Hi Sam, Please review the report. Sincerely Yours.",
                      "Hi Sam, Let's check the store. Best Buy.", "Hi Sam, Please talk to Dr. Best, Dana.", "Thanks, Sam. I'll look at it tomorrow.",
                      "Dear team,\n\nThe release is ready."] {
            XCTAssertEqual(EmailLayout.apply(prose), prose)
        }
    }
}
