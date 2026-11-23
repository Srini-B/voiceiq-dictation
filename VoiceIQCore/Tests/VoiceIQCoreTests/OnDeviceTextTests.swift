import XCTest
@testable import VoiceIQCore
import VoiceIQSpeech

// The on-device transcript as inserted with writing Off: numbers in digits
// and the Dictionary's sound-alike spellings. Cases from Hex's tests (MIT,
// github.com/anomalyco/hex at db515bda: ios/HEXMobileTests/TranscriptCleanupTests.swift
// and CustomVocabularyTests.swift); see THIRD_PARTY_NOTICES.md.
final class SpokenNumbersTests: XCTestCase {
    /// Where `written` joins a digit to a number word of the same number and `heard` didn't:
    /// "a hundred and 50", "one point 21", "oh 472". All of a number goes into digits or none.
    private static func newNumberSplits(_ heard: String, _ written: String) -> [String] {
        let numberWords: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
            "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
            "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
        ]
        func splits(_ text: String) -> [String] {
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            func bare(_ word: String) -> String {
                word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            }
            func isNumberWord(_ word: String) -> Bool {
                let parts = bare(word).split(separator: "-")
                return !parts.isEmpty && parts.allSatisfy { numberWords.contains(String($0)) }
            }
            func hasDigit(_ word: String) -> Bool { word.contains(where: \.isNumber) }
            func closes(_ word: String) -> Bool { word.last.map { ",.;:!?)\"”".contains($0) } ?? false }
            var found: [String] = []
            for index in words.indices.dropLast() where !closes(words[index]) {
                let (left, right) = (words[index], words[index + 1])
                if (hasDigit(left) && isNumberWord(right)) || (isNumberWord(left) && hasDigit(right)) {
                    found.append(left + " " + right)
                }
                let before = index > 0 && !closes(words[index - 1]) ? words[index - 1] : ""
                let joins = ["point", "oh"].contains(bare(left)) ? isNumberWord(before) || hasDigit(before)
                    : bare(left) == "and" && ["hundred", "thousand"].contains(bare(before))
                if joins, hasDigit(right) {
                    found.append(before + " " + left + " " + right)
                }
            }
            return found
        }
        var before = splits(heard)
        return splits(written).filter { split in
            guard let index = before.firstIndex(of: split) else { return true }
            before.remove(at: index)
            return false
        }
    }

    func testSpokenNumbersBecomeDigits() {
        for (heard, written) in [
            ("Between five and ten minutes.", "Between 5 and 10 minutes."),
            ("Two or three days.", "2 or 3 days."),
            ("One to two hours.", "1 to 2 hours."),
            ("Meet at seven fifteen pm.", "Meet at 7:15 pm."),
            ("Seven oh five am.", "7:05 am."),
            ("At five o'clock.", "At 5 o'clock."),
            ("It's one mile away.", "It's 1 mile away."),
            ("It costs one dollar.", "It costs $1."),
            ("Five million dollars.", "$5 million."),
            ("Two thousand and five.", "2005."),
            ("May second.", "May 2nd."),
            ("On the first of may.", "On the 1st of may."),
            ("On September thirtieth.", "On September 30th."),
            ("Five point five dollars.", "$5.50."),
            ("Call five five five, one two three, four five six seven.", "Call 555-123-4567."),
            ("Built in nineteen oh five.", "Built in 1905."),
            ("It's minus one.", "It's -1."),
            ("Twenty-five people.", "25 people."),
            ("Two hundred people.", "200 people."),
            ("Three point five million.", "3.5 million."),
            ("Twenty one guns.", "21 guns."),
            ("Six feet.", "6 feet."),
            // "a hundred" or "a thousand" that a number goes on from; a decimal with two words after
            // "point"; percent ranges; both sides of "in", "out of", "to" and a height.
            ("A hundred and fifty people came.", "150 people came."),
            ("About a hundred and twenty.", "About 120."),
            ("It was a hundred and five degrees.", "It was 105 degrees."),
            ("I gave a hundred and ten percent.", "I gave 110%."),
            ("A thousand and one nights.", "1001 nights."),
            ("One point twenty one gigawatts.", "1.21 gigawatts."),
            ("Ten to fifteen percent.", "10 to 15%."),
            ("Five to ten percent.", "5 to 10%."),
            ("Fifty one percent.", "51%."),
            ("One in ten people.", "1 in 10 people."),
            ("Eight out of ten cats.", "8 out of 10 cats."),
            ("Nine times out of ten.", "9 times out of 10."),
            ("From zero to one hundred.", "From 0 to 100."),
            ("She is five foot six.", "She is 5 foot 6."),
            ("The code is oh four seven two.", "The code is 0472."),
            ("My zip is nine oh two one oh.", "My zip is 90210."),
            // Names keep converting where the number isn't capitalised, or is the last word.
            ("Area fifty one.", "Area 51."),
            ("Apollo thirteen.", "Apollo 13."),
            ("I shop at Forever Twenty One.", "I shop at Forever 21."),
            ("iPhone seventeen pro.", "iPhone 17 pro."),
            ("Windows eleven.", "Windows 11."),
            ("Twenty people came.", "20 people came."),
        ] {
            XCTAssertEqual(SpokenNumbers.digits(in: heard, language: "en-US"), written, heard)
            XCTAssertEqual(Self.newNumberSplits(heard, written), [], heard)
        }
    }

    /// "one" alone, ordinals outside dates, fractions, and times, prices, ranges and scores
    /// without a marker or unit stay as said for now, as do digits and other languages.
    func testSpokenNumbersLeaveTheRestAsSaid() {
        for heard in [
            "One of them is broken.",
            "No one came to the meeting.",
            "That's the one I wanted.",
            "For once, it worked.",
            "To be honest, I won the game.",
            "I want to go too.",
            "Give me a second.",
            "We'll go through them one by one.",
            "We need one more chair.",
            "Use half a cup of sugar.",
            "Two thirds of the team agreed.",
            "I'll be there in one and a half hours.",
            "She finished first in the race.",
            "This is the third time I've asked.",
            "Let's meet at three thirty.",
            "The app is four ninety nine a month.",
            "Lunch was twelve fifty.",
            "The score was three to one.",
            "Kids aged eight to twelve can join.",
            "I ate breakfast at eight.",
            "We shipped build one thirty this morning.",
            "I work nine to five.",
            "The five point plan.",
            "Back in the nineteen nineties.",
            "Just my two cents.",
            "Ten to five.",
            "One or two people came.",
            "We sold 2,400 units.",
            "The app is $4.99 a month.",
            "Meet at 7:15.",
            "He lives on the twenty first floor.",
            "Have you tried GPT five yet?",
            "The deadline is march third.",
            "Two plus two equals four.",
            "Five, six, seven.",
            "Five five.",
            "It's a two-way street.",
            "Take a ten-minute break.",
            "Quarter past two.",
            "Twenty past six.",
            "Two of us went.",
            "Those two are fine.",
            "The train leaves at seven fifteen.",
            "Two dozen eggs.",
            "A hundred people.",
            // A number the engine capitalised as a name, mid-sentence or with a capital inside.
            "I love Twenty One Pilots.",
            "Use Eleven Labs for the voice.",
            "Ten Thousand Villages has nice gifts.",
            "I watched Fifty Shades of Grey.",
            "We saw Twelve Angry Men.",
            "I watch Sixty Minutes.",
            "Let's get Five Guys for lunch.",
            "We went to Six Flags.",
            // Arithmetic, "Oh", "a hundred" alone, and hundreds said short.
            "Ten minus five is five.",
            "Ten times two is twenty.",
            "Ten minus five.",
            // "one point" with a number after it is a decimal or nothing: never "one point 2".
            "At one point two people left.",
            "Oh one more thing.",
            "A hundred percent.",
            "It cost a hundred dollars.",
            "It's a couple hundred bucks.",
            "A few thousand people came.",
            "A million reasons.",
            "Half a million people.",
            "Two to three hundred people.",
            "One or two hundred people.",
        ] {
            XCTAssertEqual(SpokenNumbers.digits(in: heard, language: "en-US"), heard)
        }
        // Custom vocabulary and learned words stay as said, in any case.
        for (heard, term) in [
            ("let's get five guys for lunch", "Five Guys"),
            ("We love twenty one pilots.", "Twenty One Pilots"),
            ("I got a gift at ten thousand villages.", "Ten Thousand Villages"),
            ("I listen to nine inch nails.", "Nine Inch Nails"),
        ] {
            XCTAssertEqual(SpokenNumbers.digits(in: heard, language: "en-US", protectedTerms: [term]), heard, term)
        }
        XCTAssertEqual(SpokenNumbers.digits(in: "We love twenty one pilots.", language: "en-US"), "We love 21 pilots.")
        XCTAssertEqual(
            SpokenNumbers.digits(in: "Five guys ordered twenty five burgers.", language: "en-US", protectedTerms: ["Five Guys"]),
            "Five guys ordered 25 burgers."
        )
        // A number right before a protected term stops at the term.
        XCTAssertEqual(
            SpokenNumbers.digits(in: "We ordered twenty Five Guys burgers.", language: "en-US", protectedTerms: ["Five Guys"]),
            "We ordered 20 Five Guys burgers."
        )
        // A mark before the next word ends the number.
        XCTAssertEqual(SpokenNumbers.digits(in: "We need twenty (five optional) chairs.", language: "en-US"),
                       "We need 20 (five optional) chairs.")
        XCTAssertEqual(SpokenNumbers.digits(in: "I said twenty \"five\" times.", language: "en-US"),
                       "I said 20 \"five\" times.")
        // A new line ends a number too.
        let lines = SpokenNumbers.digits(in: "The total was twenty\nFive people left.", language: "en-US")
        XCTAssertTrue(lines.hasPrefix("The total was 20\n"), lines)
        XCTAssertEqual(SpokenNumbers.digits(in: "I said twenty one direction.", language: "en-US", protectedTerms: ["One Direction"]),
                       "I said 20 one direction.")
        XCTAssertEqual(SpokenNumbers.digits(in: "Five to zero degrees.", language: "en-US"), "Five to zero degrees.")
        XCTAssertEqual(SpokenNumbers.digits(in: "Five to one foot.", language: "en-US"), "Five to one foot.")
        // Comma-separated digit groups stop at a new line or an opening mark.
        XCTAssertFalse(SpokenNumbers.digits(in: "Call five five five,\none two three, four five six seven.", language: "en-US")
            .contains("555-123-4567"))
        XCTAssertFalse(SpokenNumbers.digits(in: "Call five five five, (one two three, four five six seven).", language: "en-US")
            .contains("555-123-4567"))
        XCTAssertEqual(SpokenNumbers.digits(in: "It costs one point two point three dollars.", language: "en-US"),
                       "It costs one point two point three dollars.")
        XCTAssertEqual(SpokenNumbers.digits(in: "Five to ten minutes.", language: "en-US"), "5 to 10 minutes.")
        XCTAssertEqual(SpokenNumbers.digits(in: "Cinco punto cinco.", language: "es-ES"), "Cinco punto cinco.")
        XCTAssertEqual(SpokenNumbers.digits(in: "The ratio is five point five.", language: "fr-FR"), "The ratio is five point five.")
    }
}

final class SoundAlikeSpellingTests: XCTestCase {
    private func spell(_ terms: [String], _ text: String, language: String = "en-US") -> String {
        SoundAlikeSpelling.apply(terms, to: text, language: language)
    }

    func testWritesTheListedSpellingOfANameHeardAnotherWay() {
        let names = ["Stacey", "Jon", "Katherine", "Sara", "Kris", "Aimee", "Bryan", "Rachael", "Meghan", "Phillip"]
        XCTAssertEqual(spell(names, "Can you send the invoice to Stacy tomorrow?"), "Can you send the invoice to Stacey tomorrow?")
        XCTAssertEqual(spell(names, "Stacy and John are coming over tonight."), "Stacey and Jon are coming over tonight.")
        XCTAssertEqual(spell(names, "We're going to Catherine's party."), "We're going to Katherine's party.")
        XCTAssertEqual(spell(names, "I borrowed Sarah’s car."), "I borrowed Sara’s car.")
        XCTAssertEqual(spell(names, "Chris sent over the designs."), "Kris sent over the designs.")
        XCTAssertEqual(spell(names, "Thanks, Amy, that helped."), "Thanks, Aimee, that helped.")
        XCTAssertEqual(spell(names, "Brian booked it with Rachel and Megan."), "Bryan booked it with Rachael and Meghan.")
        XCTAssertEqual(spell(names, "Philip is late."), "Phillip is late.")
    }

    /// Sounding alike without the same folded spelling counts only inside a sentence, where a
    /// capital means a name, and not right after another capital (a title).
    func testSoundsAlikeOnlyInsideASentence() {
        XCTAssertEqual(spell(["Geoff"], "Let's invite Jeff to the dinner."), "Let's invite Geoff to the dinner.")
        XCTAssertEqual(spell(["Vercel"], "We deploy the site on Versal."), "We deploy the site on Vercel.")
        XCTAssertEqual(spell(["Geoff"], "Jeff fixed the printer."), "Jeff fixed the printer.")
        XCTAssertEqual(spell(["Geoff"], "Done. Jeff fixed it."), "Done. Jeff fixed it.")
        XCTAssertEqual(spell(["Studio"], "We read A Study in Scarlet."), "We read A Study in Scarlet.")
    }

    func testLeavesOtherWordsAlone() {
        XCTAssertEqual(spell(["Marc"], "I mark the spot."), "I mark the spot.", "lowercase words are never names")
        XCTAssertEqual(spell(["Jon"], "Join us. Jen and Jan came."), "Join us. Jen and Jan came.")
        XCTAssertEqual(spell(["Aimee"], "Aim higher. Am I late?"), "Aim higher. Am I late?")
        XCTAssertEqual(spell(["Rune"], "Run the tests."), "Run the tests.")
        XCTAssertEqual(spell(["Sara", "Sarah"], "Sarah and Sara met."), "Sarah and Sara met.", "both are listed")
        XCTAssertEqual(spell(["kubectl", "Al"], "Ask Cubectl and Al."), "Ask Cubectl and Al.", "lowercase and short terms")
        XCTAssertEqual(spell(["Stacey"], "STACY said hi."), "STACY said hi.", "all capitals")
        XCTAssertEqual(spell(["Stacey"], "Stacy hat angerufen.", language: "de-DE"), "Stacy hat angerufen.", "English only")
    }

    func testAWordOfAListedTermStays() {
        XCTAssertEqual(spell(["Stacy Smith", "Stacey"], "Ask Stacy Smith tomorrow."), "Ask Stacy Smith tomorrow.")
    }

    func testQuotesAndBracketsAroundAName() {
        XCTAssertEqual(spell(["Stacey"], "Tell 'Stacy' today."), "Tell 'Stacey' today.")
        XCTAssertEqual(spell(["Vercel"], "Notes. [Versal is next.]"), "Notes. [Versal is next.]")
    }

    func testTwoTermsThatFitEquallyLeaveTheWordAsHeard() {
        XCTAssertEqual(spell(["Stacey", "Stacie"], "Ask Stacy."), "Ask Stacy.")
    }
}
