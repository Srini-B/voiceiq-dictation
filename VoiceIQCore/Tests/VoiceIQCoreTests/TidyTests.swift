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
