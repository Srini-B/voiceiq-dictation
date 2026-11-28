import XCTest
@testable import VoiceIQCore

/// The writing-Off tidy-up. Expected texts are Hex's own test cases
/// (src/dictation/style/tests.rs, filler_words.rs, spoken_formatting.rs and
/// spoken_symbols.rs at 012bdbbe), with VoiceiQ's style names.
final class TidyTests: XCTestCase {
    private func tidy(_ text: String, _ style: TidyStyle = .sentences, _ language: String = "en-US") -> String {
        Tidy.styled(Tidy.spoken(text, style: style, language: language), style: style, language: language)
    }

    private func styles(_ text: String) -> [String] {
        [TidyStyle.sentences, .messages, .lists, .asSpoken].map { tidy(text, $0) }
    }

    func testEachStyleWritesAShortDictationItsOwnWay() {
        XCTAssertEqual(styles("Sounds good, see you at 5."),
                       ["Sounds good, see you at 5.", "sounds good, see you at 5", "Sounds good, see you at 5", "Sounds good, see you at 5."])
        XCTAssertEqual(styles("Um, buy milk. Call the dentist. Book the flights."),
                       ["Buy milk. Call the dentist. Book the flights.", "buy milk. call the dentist. book the flights",
                        "- Buy milk\n- Call the dentist\n- Book the flights", "Um, buy milk. Call the dentist. Book the flights."])
        XCTAssertEqual(styles("i'm running late start without me"),
                       ["I'm running late start without me.", "i'm running late start without me",
                        "I'm running late start without me", "i'm running late start without me"])
        for style in TidyStyle.allCases { XCTAssertEqual(tidy("  \n ", style), "") }
    }

    func testSentences() {
        XCTAssertEqual(tidy("erm i think i'll go, it's fine"), "I think I'll go, it's fine.")
        XCTAssertEqual(tidy("first line\nsecond line"), "First line.\nSecond line.")
        XCTAssertEqual(tidy("I'm gonna call. He said \"gonna win\""), "I'm going to call. He said \"gonna win\"")
        XCTAssertEqual(tidy("send it to john@gmail.com"), "Send it to john@gmail.com.")
        XCTAssertEqual(tidy("john@gmail.com"), "john@gmail.com")
        XCTAssertEqual(tidy("Hello. world! ok? yes"), "Hello. World! Ok? Yes.")
        XCTAssertEqual(tidy("say i'"), "Say i'.")
    }

    func testMessages() {
        XCTAssertEqual(tidy("Yeah, I'll text John about the iPhone order tomorrow.", .messages),
                       "yeah i'll text John about the iPhone order tomorrow")
        XCTAssertEqual(tidy("OK, can you send me the deck?", .messages), "ok can you send me the deck?")
        XCTAssertEqual(tidy("NASA launched it. Wow!", .messages), "NASA launched it. wow!")
        XCTAssertEqual(tidy("One. Two. Three. Four.", .messages), "one. two. three. four.")
        XCTAssertEqual(tidy("I think I can, i.e. maybe.", .messages), "i think i can, i.e. maybe")
    }

    func testLists() {
        XCTAssertEqual(tidy("So, first, buy milk. And then call the dentist.", .lists), "- Buy milk\n- Call the dentist")
        XCTAssertEqual(tidy("Shopping list: eggs, milk, and bread.", .lists), "Shopping list:\n- Eggs\n- Milk\n- Bread")
        // A choice stays a sentence: a list would make "milk or bread" two requests.
        XCTAssertEqual(tidy("Shopping list: eggs, milk or bread.", .lists), "Shopping list: eggs, milk or bread")
        XCTAssertEqual(tidy("Dr. Patel called. Call her back.", .lists), "- Dr. Patel called\n- Call her back")
        XCTAssertEqual(tidy("Note: the build is green.", .lists), "Note: the build is green")
        XCTAssertEqual(tidy("bullet point ship it bullet point tag it", .lists), "- Ship it\n- Tag it")
        XCTAssertEqual(tidy("Groceries, new line, milk. New paragraph, then eggs", .lists), "Groceries\nMilk\n\nThen eggs")
        XCTAssertEqual(tidy("买牛奶。给妈妈打电话。", .lists, "zh-CN"), "- 买牛奶\n- 给妈妈打电话")
    }

    /// Each language drops only its own hesitations: Norwegian "er" is "is",
    /// Portuguese "um" is "a", German "eh" is "anyway", Spanish "e" is "and".
    func testHesitationsFollowTheDictationLanguage() {
        XCTAssertEqual(tidy("det er bra, eh, vi ses", .sentences, "nb-NO"), "Det er bra, vi ses.")
        XCTAssertEqual(tidy("um café, por favor", .messages, "pt-BR"), "um café, por favor")
        XCTAssertEqual(tidy("Äh, das ist eh egal.", .sentences, "de-DE"), "Das ist eh egal.")
        XCTAssertEqual(tidy("Eh, ¿qué tal? Padre e hijo.", .sentences, "es-ES"), "¿Qué tal? Padre e hijo.")
        XCTAssertEqual(tidy("Mmm, creo que sí, eh, pero no estoy seguro.", .sentences, "es-ES"), "Creo que sí, pero no estoy seguro.")
        XCTAssertEqual(tidy("i think it's gonna work", .sentences, "it-IT"), "I think it's gonna work.")
        XCTAssertEqual(tidy("Um, uh.", .sentences), "")
    }

    func testEnglishHesitationsGoWithTheirCommasAndHandOnTheirCapital() {
        XCTAssertEqual(Hesitations.removing(from: "So, um, we should go."), "So, we should go.")
        XCTAssertEqual(Hesitations.removing(from: "Well umm... maybe"), "Well maybe")
        XCTAssertEqual(Hesitations.removing(from: "Hello. Uh, we left. Ah. Then"), "Hello. We left. Ah. Then")
        XCTAssertEqual(Hesitations.removing(from: "First line.\nUm, second"), "First line.\nSecond")
        for kept in ["The umbrella is ahead of the error.", "Uhura said uh-huh.", "Take him to the ER.", "UM is a university."] {
            XCTAssertEqual(Hesitations.removing(from: kept), kept)
        }
    }

    /// The disfluencies Hex's cleanup guard admits (CleanupGuard.swift,
    /// guard_tests.rs at a0f0a858 and e27726790), each beside the near miss
    /// that must stay. Input is punctuated as a cloud transcript arrives.
    func testCommaSetFillersGoWithTheirCommas() {
        for (said, written) in [
            ("I like it, like, a lot.", "I like it a lot."),
            ("I went, like, to the store.", "I went to the store."),
            ("It was, you know, pretty late.", "It was pretty late."),
            ("Like, I don't know.", "I don't know."),
            ("You know, I think it works.", "I think it works."),
            // A clause of one word keeps its comma.
            ("So, like, we should go.", "So, we should go."),
            ("We left, like, you know, after lunch.", "We left after lunch."),
            ("We left, you know, like, after lunch.", "We left after lunch."),
            ("You know, like, I think it works.", "I think it works."),
            ("It took, you know, like, five hours.", "It took, like, five hours."),
            // A run is judged by the words around all of it.
            ("It took, like, you know, five hours.", "It took, like, five hours."),
            ("Use a tool, like, you know, a hammer.", "Use a tool, like, a hammer."),
            ("I went, like, you know, to the store.", "I went to the store."),
        ] {
            XCTAssertEqual(tidy(said), written, said)
        }
        // "like" as the verb or "such as", a list, a question tag.
        for kept in ["It was like a dream.", "Arrange the folders like we did yesterday.", "Like, comment and share.",
                     "Please share, like, and comment.", "Please follow, like, subscribe, and share.",
                     "Wait, you know, right?", "You know, don't you, that the meeting is tomorrow?",
                     "You know, of course, that this is confidential.",
                     // Quoting, "about", "such as", and a "you know" that is the question.
                     "And he was, like, I'm not going.", "She was, like, what are you doing?",
                     "It took, like, five hours.", "It took, like, 5 hours.", "It cost, like, thirteen dollars.", "It cost, like, $50 yesterday.",
                     "It took, like, a hundred hours.", "Use a tool, like, a hammer.",
                     "We need supplies, like, paper and pens.",
                     "Bring a tool, like, my hammer.", "Use a tool, like, this one.",
                     "She goes, like, before you leave, call me.", "And I'm, like, no way.",
                     "Do it, like, you did last time.", "Do it, like, you  did last time.",
                     "Like, this video before subscribing.", "Done. Like, the build passed.",
                     // A run kept whole is not judged again from its middle.
                     "You know, like, of course, that this is confidential.", "He said 'Hello', like, you know, to everyone.",
                     "She was, like, like, what are you doing?", "Like, you know, five hours.", "You know, like, five hours.",
                     "We met, you know, Like, to discuss it.", "Arrange the folders, like, we did yesterday.", "We saw cities, like, Paris and Rome.",
                     "I told Sam, like, Priya said no.", "Wait, you know, don't you?"] {
            XCTAssertEqual(tidy(kept), kept)
        }
    }

    func testRepeatsGoOnlyWhereNoWordIsMeantTwice() {
        for (said, written) in [
            ("I I think so.", "I think so."),
            ("Put it on the the shelf.", "Put it on the shelf."),
            ("We went to the, the office.", "We went to the office."),
            ("The, the office is closed.", "The office is closed."),
            ("In the, in the morning, we left.", "In the morning, we left."),
            ("Um, we we should, uh, leave.", "We should leave."),
            ("w- we should go", "We should go."),
        ] {
            XCTAssertEqual(tidy(said), written, said)
        }
        // Grammatical pairs, emphasis, names, distinct list items and compounds.
        for kept in ["I had had enough.", "I know that that works.", "Whatever you do, do it well.",
                     "That was really, really good.", "No, no, no.", "Priya, Priya, are you there?",
                     "Will, Will, are you there?", "A box of red pencils, a box of blue pencils.",
                     "Pack a bag of tea, a bag of tea.", "Tell Hye-jin I said thanks.",
                     "Who am I, I wonder?", "Who are we, we who stayed behind?",
                     // Single quotes are quotes; prefixes and "No-" are not cut-offs.
                     "He wrote 'the the' on the board.", "He wrote 'put the the book on the shelf' on the board.",
                     "He wrote ‘put the the book away’ today.", "Please re- read the draft.", "A- average work.",
                     "No- not now."] {
            XCTAssertEqual(tidy(kept), kept)
        }
    }

    func testFalseStartsGoWhenTheQuestionRestarts() {
        for (said, written) in [
            ("Did you, have you seen it?", "Have you seen it?"),
            ("Did you, did you see it?", "Did you see it?"),
            ("So, can you, could you send it?", "So, could you send it?"),
            // What is left is asked: the question mark comes after the false start goes.
            ("Can you, would you open it", "Would you open it?"),
        ] {
            XCTAssertEqual(tidy(said), written, said)
        }
        for kept in ["If you can, call me.", "When you can, can you call me?", "Should we, could we, would we?",
                     "Should we, could we, would we go?"] {
            XCTAssertEqual(tidy(kept), kept)
        }
    }

    /// "I mean" is left to `SpokenRepairs`, which resolves only a like-for-like
    /// correction, and quoted words are kept as said.
    func testIMeanAndQuotedWordsStayAsSaid() {
        XCTAssertEqual(tidy("Let's meet Monday, I mean, Tuesday."), "Let's meet Tuesday.")
        for kept in ["It's good. I mean, really good.", "We met on Friday, I mean, Monday works too.",
                     "It was, I mean, pretty good.", "He wrote \"the the\" on the board.",
                     "She said \"I went, like, home\" and left."] {
            XCTAssertEqual(tidy(kept), kept)
        }
    }

    func testSpokenLayout() {
        XCTAssertEqual(SpokenMarks.layout(in: "Hello. New line. Next"), "Hello.\nNext")
        XCTAssertEqual(SpokenMarks.layout(in: "One. New paragraph. Two."), "One.\n\nTwo.")
        XCTAssertEqual(SpokenMarks.layout(in: "He said, Open quote, hello, close quote, and left."), "He said, \"hello\", and left.")
        XCTAssertEqual(SpokenMarks.layout(in: "He said quote hello unquote."), "He said \"hello\".")
        XCTAssertEqual(SpokenMarks.layout(in: "Hola. Nuevo párrafo. Adiós.", language: "es-ES"), "Hola.\n\nAdiós.")
        for kept in ["quote unquote experts", "The newline character", "renew line items", "open quotes", "Can I get a quote for this"] {
            XCTAssertEqual(SpokenMarks.layout(in: kept), kept)
        }
    }

    func testSpokenSymbols() {
        XCTAssertEqual(SpokenMarks.symbols(in: "Dear Sam comma thanks"), "Dear Sam, thanks")
        XCTAssertEqual(SpokenMarks.symbols(in: "Is it ready question mark"), "Is it ready?")
        // Names that are also prose words, and Spanish marks, stay as said.
        for kept in ["commas", "hashtag release", "my underscore variable", "and slash or", "the colonel",
                     "Colon biopsy results", "a bigger colon", "comma separated values", "one question mark left",
                     "Hey Comma, can you check this?", "He typed, comma, nothing else.", "Hi comma club members",
                     "Note, comma, goes inside the quotes."] {
            XCTAssertEqual(SpokenMarks.symbols(in: kept), kept)
        }
        for kept in ["mi guion bajo variable", "la lista dos puntos manzanas", "Juan coma bien"] {
            XCTAssertEqual(SpokenMarks.symbols(in: kept, language: "es-ES"), kept)
        }
        for kept in ["a hash browns sign"] {
            XCTAssertEqual(SpokenMarks.symbols(in: kept), kept)
        }
    }

    /// Hex's address cases (ios/HEXMobileTests/TranscriptCleanupTests.swift):
    /// "at the rate" is "@" only before a domain, even one Apple's models
    /// glue to "rate" or "sign".
    func testSpokenAddresses() {
        for (spoken, written) in [
            ("My email is priya dot sharma at the rate company dot co dot in.",
             "My email is priya.sharma@company.co.in."),
            ("ravi at the rate, gmail dot com", "ravi@gmail.com"),
            ("My email is John at the rategmail.com.", "My email is john@gmail.com."),
            ("Send it to Priya at signyahoo.com.", "Send it to priya@yahoo.com."),
        ] {
            XCTAssertEqual(SpokenAddresses.joining(in: spoken), written)
        }
        for kept in ["At the rate you're going, you'll finish early.", "john at the rate gmail", "Wait at the gate dot com",
                     "Rates went up at the ratepayers' meeting.", "My email is john at gmail.com.",
                     "We grew at the rate Amazon dot com predicted.", "The password is \"john at sign gmail dot com\"."] {
            XCTAssertEqual(SpokenAddresses.joining(in: kept), kept)
        }
    }

    /// "As spoken" keeps every word, spoken marks included.
    func testAsSpokenKeepsTheWords() {
        XCTAssertEqual(tidy("  um keep   raw words new line comma  ", .asSpoken), "um keep raw words new line comma")
    }
}
