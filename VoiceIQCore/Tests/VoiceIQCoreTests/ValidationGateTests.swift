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

    /// The writer repeated the line's marker or greeting that the field
    /// already holds; the field would show it twice.
    func testDropsTextTheFieldAlreadyEndsWith() {
        XCTAssertEqual(ValidationGate.droppingEcho("[2] The caterer needs a head count.", before: "[1] Venue booked.\n[2] ",
                                                   transcript: "okay so the caterer needs a head count"),
                       "The caterer needs a head count.")
        XCTAssertEqual(ValidationGate.droppingEcho("- Phone charger\n- Adapter", before: "Packing\n- Passport\n- ",
                                                   transcript: "phone charger and the adapter"),
                       "Phone charger\n- Adapter")
        XCTAssertEqual(ValidationGate.droppingEcho("Hi Omar, it looks better.", before: "Hi Omar, ",
                                                   transcript: "it looks better"),
                       "it looks better.")
        XCTAssertEqual(ValidationGate.droppingEcho("[1] Okay, one more thing.", before: "[1] ", transcript: "okay one more thing"),
                       "Okay, one more thing.")
        XCTAssertEqual(ValidationGate.droppingEcho("we should push the launch", before: "Thanks. I think we should ",
                                                   transcript: "push the launch to next week"),
                       "push the launch")
        XCTAssertEqual(ValidationGate.droppingEcho("Notes: Rahul wants to move teams, per my notes.", before: "1:1\nNotes: ",
                                                   transcript: "rahul wants to move teams per my notes"),
                       "Rahul wants to move teams, per my notes.")
    }

    /// Words the speaker said, or that only look like the field's end, stay.
    func testKeepsASpokenRepeatAndLookalikes() {
        XCTAssertEqual(ValidationGate.droppingEcho("Hi Omar, it looks better.", before: "Hi Omar, ",
                                                   transcript: "hi omar it looks better"),
                       "Hi Omar, it looks better.")
        XCTAssertEqual(ValidationGate.droppingEcho("The report is ready.", before: "I sent the", transcript: "report is ready"),
                       "The report is ready.")
        XCTAssertEqual(ValidationGate.droppingEcho("3.5 million signed up.", before: "Totals 3.", transcript: "three point five million"),
                       "3.5 million signed up.")
        XCTAssertEqual(ValidationGate.droppingEcho("[1]", before: "[1] ", transcript: "one"), "[1]")
        XCTAssertEqual(ValidationGate.droppingEcho("Hi Priya, the deck looks good.", before: "Hi Priya,",
                                                   transcript: "so um hi priya the deck looks good"),
                       "Hi Priya, the deck looks good.")
        XCTAssertEqual(ValidationGate.droppingEcho("2024 was our best year.", before: "Revenue grew every year since 2024",
                                                   transcript: "twenty twenty four was our best year"),
                       "2024 was our best year.")
        XCTAssertEqual(ValidationGate.droppingEcho("Okay, let's go.", before: "Notes\nOkay", transcript: "um okay let's go"),
                       "Okay, let's go.")
        XCTAssertEqual(ValidationGate.droppingEcho("3. Buy milk.", before: "1. Eggs\n2. Bread\n3. ", transcript: "three buy milk"),
                       "3. Buy milk.")
        XCTAssertEqual(ValidationGate.droppingEcho("-5 degrees this morning.", before: "Temps\n- ",
                                                   transcript: "minus five degrees this morning"),
                       "-5 degrees this morning.")
        XCTAssertEqual(ValidationGate.droppingEcho("3.5 million signed up.", before: "Totals 3.",
                                                   transcript: "about three point five million signed up"),
                       "3.5 million signed up.")
        XCTAssertEqual(ValidationGate.droppingEcho("2. Call the venue.", before: "That makes 12.", transcript: "call the venue"),
                       "2. Call the venue.")
        XCTAssertEqual(ValidationGate.droppingEcho("[1]", before: "[1] ", transcript: "okay"), "[1]")
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
