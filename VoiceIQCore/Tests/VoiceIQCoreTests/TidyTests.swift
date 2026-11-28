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
        // A title's full stop ends no sentence, so this is one short message.
        XCTAssertEqual(tidy("Ask Prof. Iyer and Sgt. Lee and Capt. Rao.", .messages), "ask Prof. Iyer and Sgt. Lee and Capt. Rao")
        // A title word ending a longer message keeps its full stop; alone it is the one to drop.
        XCTAssertEqual(tidy("Thanks. Ask Martin Luther King Jr.", .messages), "thanks. ask Martin Luther King Jr.")
        XCTAssertEqual(tidy("Sounds good. The invoice is from Acme Inc.", .messages), "sounds good. the invoice is from Acme Inc.")
        XCTAssertEqual(tidy("Ask Martin Luther King Jr.", .messages), "ask Martin Luther King Jr")
        XCTAssertEqual(tidy("Ask Dr. Smith Jr.", .messages), "ask Dr. Smith Jr.")
        XCTAssertEqual(tidy("Sounds good! The invoice is from Acme Inc.", .messages), "sounds good! the invoice is from Acme Inc.")
        // "No." is a title only before a number ("No. 5"); here it is one of four sentences.
        XCTAssertEqual(tidy("Is it ok? No. Call me later. See you.", .messages), "is it ok? no. call me later. see you.")
    }

    func testLists() {
        XCTAssertEqual(tidy("So, first, buy milk. And then call the dentist.", .lists), "- Buy milk\n- Call the dentist")
        XCTAssertEqual(tidy("Shopping list: eggs, milk, and bread.", .lists), "Shopping list:\n- Eggs\n- Milk\n- Bread")
        // A choice stays a sentence: a list would make "milk or bread" two requests.
        XCTAssertEqual(tidy("Shopping list: eggs, milk or bread.", .lists), "Shopping list: eggs, milk or bread")
        XCTAssertEqual(tidy("Dr. Patel called. Call her back.", .lists), "- Dr. Patel called\n- Call her back")
        XCTAssertEqual(tidy("Note: the build is green.", .lists), "Note: the build is green")
        XCTAssertEqual(tidy("bullet point ship it bullet point tag it", .lists), "- Ship it\n- Tag it")
        XCTAssertEqual(tidy("Groceries: bullet point milk, bullet point eggs; bullet point bread.", .lists),
                       "Groceries:\n- Milk\n- Eggs\n- Bread")
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
        // A run of hesitations is still hesitations; "As spoken" keeps a stammer that is meant.
        XCTAssertEqual(tidy("He kept going uh, uh, uh."), "He kept going.")
        XCTAssertEqual(tidy("He kept going uh, uh, uh.", .asSpoken), "He kept going uh, uh, uh.")
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
            // The comma that addresses someone stays.
            ("Let's eat, you know, grandma and grandpa.", "Let's eat, grandma and grandpa."),
            // A double space hides nothing from the run's judgment (Tidy closes it up).
            ("Do it, like, you  did last time.", "Do it, like, you did last time."),
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
                     "Do it, like, you did last time.",
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
                     "No- not now.", "B- blood is needed urgently."] {
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
        XCTAssertEqual(tidy("It took 101, I mean, 102 minutes."), "It took 102 minutes.")
        XCTAssertEqual(tidy("Meet at gate 12, I mean, 14."), "Meet at gate 14.")
        // A unit after a number that names something may be a second fact: "flight 101, 102 minutes long".
        for kept in ["Flight 101, I mean, 102 minutes.", "It's good. I mean, really good.", "We met on Friday, I mean, Monday works too.",
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
        // Set off by commas, "new line" breaks the line unless only a hedge follows: then the words name something.
        XCTAssertEqual(tidy("Yeah, I'll ping Sam, new line, thanks.", .messages), "yeah i'll ping Sam\nthanks.")
        XCTAssertEqual(tidy("I bought the milk, new line, then I left."), "I bought the milk.\nThen I left.")
        for kept in ["She bought a car, new line, I think.", "It's their new model, new line, I guess.", "It's the blue one, new line, I think so."] {
            XCTAssertEqual(tidy(kept), kept)
        }
    }

    func testSpokenSymbols() {
        XCTAssertEqual(SpokenMarks.symbols(in: "Dear Sam comma thanks"), "Dear Sam, thanks")
        XCTAssertEqual(SpokenMarks.symbols(in: "Is it ready question mark"), "Is it ready?")
        // One word ends a clause only when it is said as an exclamation or a question.
        XCTAssertEqual(SpokenMarks.symbols(in: "Great exclamation mark see you soon."), "Great! see you soon.")
        XCTAssertEqual(SpokenMarks.symbols(in: "Really question mark I doubt it."), "Really? I doubt it.")
        XCTAssertEqual(SpokenMarks.symbols(in: "Double exclamation mark please see it."), "Double exclamation mark please see it.")
        for kept in ["What question mark? I didn't type one.", "Really question mark? I didn't type one."] {
            XCTAssertEqual(SpokenMarks.symbols(in: kept), kept)
        }
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
            // Before "and" and another address, and before a courtesy after a comma.
            ("Mail priya at the rate gmail dot com and ravi at the rate gmail dot com.", "Mail priya@gmail.com and ravi@gmail.com."),
            ("Write to priya at the rate gmail dot com or ravi at sign gmail dot com.", "Write to priya@gmail.com or ravi@gmail.com."),
            ("Mail priya@gmail.com and ravi at the rate gmail dot com.", "Mail priya@gmail.com and ravi@gmail.com."),
            ("priya at the rate gmail dot com, please.", "priya@gmail.com, please."),
            ("Mail john at the rate gmail dot com, thanks.", "Mail john@gmail.com, thanks."),
            ("Send it to ahmed at the rate gmail dot com.", "Send it to ahmed@gmail.com."),
            ("Contacts\npriya at the rate gmail dot com.", "Contacts\npriya@gmail.com."),
            ("My email's priya at the rate gmail dot com, thanks.", "My email's priya@gmail.com, thanks."),
            ("It’s priya at the rate gmail dot com.", "It’s priya@gmail.com."),
            ("Send it to billing at the rate company dot com.", "Send it to billing@company.com."),
            ("Send it to 123 at the rate gmail dot com.", "Send it to 123@gmail.com."),
            ("Tell priya at the rate gmail dot com, thanks.", "Tell priya@gmail.com, thanks."),
            ("My email will be priya at the rate gmail dot com.", "My email will be priya@gmail.com."),
            ("Contact me via priya at the rate gmail dot com.", "Contact me via priya@gmail.com."),
            ("My email will be billing at the rate gmail dot com.", "My email will be billing@gmail.com."),
            ("And priya at the rate gmail dot com.", "And priya@gmail.com."),
            ("Send it to priya at the rate gmail dot com or ravi at sign yahoo dot com.", "Send it to priya@gmail.com or ravi@yahoo.com."),
            // A list of addresses ends where its last one does.
            ("Send it to priya at the rate gmail dot com and ravi at the rate yahoo dot com.",
             "Send it to priya@gmail.com and ravi@yahoo.com."),
            ("Send it to ming at the rate gmail dot com.", "Send it to ming@gmail.com."),
            ("Send it from 123 dot support at the rate gmail dot com.", "Send it from 123.support@gmail.com."),
            ("My email's billing at the rate gmail dot com.", "My email's billing@gmail.com."),
            // A comma that ends an address, and words that name one, still introduce an "-ing" mailbox.
            ("cc priya@gmail.com, marketing at the rate acme dot com.", "cc priya@gmail.com, marketing@acme.com."),
            ("cc priya at sign gmail dot com, accounting at the rate acme dot com.",
             "cc priya@gmail.com, accounting@acme.com."),
            ("The contact is billing at the rate acme dot com.", "The contact is billing@acme.com."),
            ("The CC is accounting at the rate acme dot com.", "The CC is accounting@acme.com."),
        ] {
            XCTAssertEqual(SpokenAddresses.joining(in: spoken), written)
        }
        for kept in ["At the rate you're going, you'll finish early.", "john at the rate gmail", "Wait at the gate dot com",
                     "Rates went up at the ratepayers' meeting.", "My email is john at gmail.com.",
                     "We grew at the rate Amazon dot com predicted.", "The password is \"john at sign gmail dot com\".",
                     // With "at the rate", a verb is no mailbox, and a comma ends no address before more words.
                     "Prices rose at the rate gmail dot com.",
                     "Mail priya at the rate gmail dot com and ravi at the rate gmail dot com predicted it.",
                     "priya at the rate gmail dot com, Walmart and Target agreed.",
                     // Before ", thanks" or another address, "is" or a written address is too weak an introduction.
                     "The market is moving at the rate google dot com, thanks.",
                     "I wrote to priya@gmail.com and growth at the rate google dot com, thanks.",
                     "It is growing at the rate amazon dot com.", "It will be growing at the rate amazon dot com.",
                     "Prices rose and fell at the rate gmail dot com.",
                     "Tell me whether the market is moving at the rate google dot com, thanks.", "Revenue went from 5 or 10 at the rate amazon dot com.", "It's growing at the rate amazon dot com.", "Revenue went from 10 at the rate amazon dot com.",
                     // A weak word earlier, a strong word before a verb, a comma before a verb or number.
                     "Prices in Europe rose and fell at the rate gmail dot com.",
                     "Tell me it will be growing at the rate amazon dot com.",
                     "Prices kept rising, growing at the rate gmail dot com.",
                     "Growth went up, 10 at the rate amazon dot com."] {
            XCTAssertEqual(SpokenAddresses.joining(in: kept), kept)
        }
    }

    /// "As spoken" keeps every word, spoken marks included.
    func testAsSpokenKeepsTheWords() {
        XCTAssertEqual(tidy("  um keep   raw words new line comma  ", .asSpoken), "um keep raw words new line comma")
    }
}
