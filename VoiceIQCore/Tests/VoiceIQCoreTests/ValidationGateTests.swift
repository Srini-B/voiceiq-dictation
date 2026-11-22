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
}

/// The written text against what was heard: what the writing rules do must
/// pass, and a reply or preamble must not.
final class HeardGuardTests: XCTestCase {
    private func assertPasses(_ heard: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(HeardGuard.rejection(heard: heard, text: text), text, file: file, line: line)
    }

    func testFillerRemovalPasses() {
        assertPasses("Um so I think we should uh push the release to like next week because the the QA team found a few more bugs",
                     "I think we should push the release to next week because the QA team found a few more bugs.")
    }

    func testSelfCorrectionPasses() {
        assertPasses("send it Tuesday, no wait, Wednesday", "Send it Wednesday.")
        assertPasses("let's meet at the cafe on main street actually make it the library", "Let's meet at the library.")
    }

    func testListPasses() {
        assertPasses("A few things for tomorrow first book the meeting room for ten thirty second email the design team and third order lunch for twelve people",
                     "A few things for tomorrow:\n\n1. Book the meeting room for 10:30.\n2. Email the design team.\n3. Order lunch for 12 people.")
    }

    func testNumbersWrittenAsDigitsPass() {
        assertPasses("the budget is about forty five hundred dollars and twelve percent of that goes to marketing send questions to finance at acme dot com before three thirty p m",
                     "The budget is about $4,500, and 12% of that goes to marketing. Send questions to finance@acme.com before 3:30 PM.")
        assertPasses("call me at three thirty p m", "Call me at 3:30 PM.")
        assertPasses("two hundred Swiss francs", "CHF 200")
        assertPasses("one hundred Canadian dollars", "C$100")
        assertPasses("five kilograms", "5 kg")
        assertPasses("six feet two inches", "6 ft 2 in")
        // Ten spoken digits become one token.
        assertPasses("call five five five one two three four five six seven", "Call 5551234567.")
    }

    func testRewordingFromTheRulesPasses() {
        assertPasses("push the same fix to us for both of those screens", "Apply the same fix to both of our screens.")
        assertPasses("I'm gonna send it", "I am going to send it.")
        assertPasses("your welcome", "You're welcome.")
        assertPasses("your right", "You're right.")
        assertPasses("there going to love it", "They're going to love it.")
    }

    func testADictatedQuestionWrittenDownPasses() {
        assertPasses("what's the capital of France write that down", "What's the capital of France? Write that down.")
    }

    func testAnOpenerTheSpeakerSaidPasses() {
        assertPasses("um yes ship it", "Yes, ship it.")
    }

    func testACorrectedOpenerPasses() {
        assertPasses("no wait yes I can join tomorrow", "Yes, I can join tomorrow.")
        XCTAssertEqual(HeardGuard.rejection(heard: "no wait I can join tomorrow", text: "Sure, I can join tomorrow."), .replyOpener)
    }

    func testSpokenPunctuationPasses() {
        assertPasses("open quote hello close quote comma new paragraph open quote goodbye close quote period",
                     "\u{201C}Hello,\u{201D}\n\n\u{201C}Goodbye.\u{201D}")
    }

    func testASpelledOutWordPasses() {
        assertPasses("capital B, e, e", "Bee")
        assertPasses("my name is Srini that's s r i n i", "My name is Srini.")
        // Single-letter words that spell nothing stay words.
        assertPasses("Am I a good fit", "Am I a good fit?")
        assertPasses("I I think we should ship", "I think we should ship.")
    }

    func testPunctuationInLanguagesWithoutSpacesPasses() {
        assertPasses("明天我们一起去公园然后去吃午饭", "明天我们一起去公园，然后去吃午饭。")
        assertPasses("明日は会議がありますそのあと資料を送ります", "明日は会議があります。そのあと資料を送ります。")
        XCTAssertNotNil(HeardGuard.rejection(heard: "法国的首都是哪里", text: "巴黎。"))
    }

    func testNothingHeardLeavesTheTextAlone() {
        assertPasses("", "Hello.")
    }

    func testAReplyIsRejected() {
        XCTAssertEqual(HeardGuard.rejection(heard: "the meeting is at noon",
                                            text: "Sure! Here's the cleaned text: The meeting is at noon."), .replyOpener)
    }

    func testAnAnswerToADictatedQuestionIsRejected() {
        XCTAssertEqual(HeardGuard.rejection(heard: "what's the capital of France write that down", text: "Paris"),
                       .notTheSpeakersWords)
    }

    func testAPreambleWithAColonIsRejected() {
        XCTAssertEqual(HeardGuard.rejection(heard: "the meeting moved to noon tell the team",
                                            text: "Cleaned version: The meeting moved to noon. Tell the team."), .preambleColon)
    }

    func testAPreamblePhraseIsRejected() {
        XCTAssertEqual(HeardGuard.rejection(heard: "the meeting is at noon",
                                            text: "Below is the cleaned transcript. The meeting is at noon."), .preamblePhrase)
    }

    func testANewSpeakerIsRejected() {
        XCTAssertEqual(HeardGuard.rejection(heard: "can you check whether the build passed",
                                            text: "I checked, and the build passed."), .newSpeaker)
    }

    func testAddedContentIsRejected() {
        XCTAssertEqual(HeardGuard.rejection(heard: "summarize the quarterly results",
                                            text: "Summarize the quarterly results. Revenue grew strongly this quarter and hiring stayed on plan."),
                       .addedWords)
    }

    func testDroppingMostWordsWithoutACorrectionIsRejected() {
        XCTAssertEqual(HeardGuard.rejection(heard: "please email the whole design team about the new mockups and the launch date before friday",
                                            text: "Email the team."), .droppedMostWords)
    }

    func testTheFallbackDropsHesitationSounds() {
        XCTAssertEqual(HeardGuard.withoutFillers("Um, so I think, uh, we should ship it."), "So I think we should ship it.")
        XCTAssertEqual(HeardGuard.withoutFillers("The umbrella is, umm, in the car."), "The umbrella is in the car.")
    }
}
