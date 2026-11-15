import UIKit
import VoiceIQBridge

/// What a key does.
enum KeyAction: Equatable {
    case insert(String)
    case shift
    case delete
    case space
    case returnKey
    case globe
    case emoji
    case page(KeyPage)
}

enum KeyPage: Equatable {
    case letters, numbers, symbols
    /// Number, decimal and phone pads: digits only.
    case digits
    /// The number pad opened from the 123 page in a text field.
    case numpad
}

struct KeySpec: Equatable {
    enum Width: Equatable {
        /// One letter key.
        case unit
        /// A multiple of a letter key.
        case units(CGFloat)
        /// Shares what the row has left: the space bar.
        case flexible
        /// A fraction of a flexible key, gap included: two halves fill one.
        case share(CGFloat)
    }
    var action: KeyAction
    var label: String
    var alternates: [String] = []
    var width: Width = .unit
    /// A small character in the key's corner: what holding it types first.
    var hint: String?
    /// Drawn without a key face, as the number pad's delete is on iOS.
    var plain = false

    var isLetter: Bool {
        if case .insert(let text) = action { return text.count == 1 && text.first!.isLetter }
        return false
    }
}

/// The field the keyboard is typing into, as far as the layout cares.
struct FieldTraits: Equatable {
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var showsGlobe = true

    var isDigitPad: Bool {
        [.numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad].contains(keyboardType)
    }

    var returnLabel: String {
        switch returnKeyType {
        case .go: return "go"
        case .google, .yahoo, .search: return "search"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .send: return "send"
        case .done: return "done"
        case .emergencyCall: return "SOS"
        case .continue: return "continue"
        default: return "return"
        }
    }
}

enum KeyLayout {
    static func letterRows(_ layout: KeyboardLetterLayout) -> [String] {
        switch layout {
        case .qwerty: return ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .qwertz: return ["qwertzuiop", "asdfghjkl", "yxcvbnm"]
        case .azerty: return ["azertyuiop", "qsdfghjklm", "wxcvbn"]
        case .dvorak: return ["pyfgcrl", "aoeuidhtns", "qjkxbmwvz"]
        case .colemak: return ["qwfpgjluy", "arstdhneio", "zxcvbkm"]
        }
    }

    static let accents: [Character: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"], "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"], "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "u": ["û", "ü", "ù", "ú", "ū"], "c": ["ç", "ć", "č"], "n": ["ñ", "ń"], "s": ["ß", "ś", "š"],
        "y": ["ÿ"], "z": ["ž", "ź", "ż"], "l": ["ł"],
    ]

    /// The region's currency first: ₹ in India, € in Germany.
    static var currency: String {
        let local = Locale.current.currencySymbol ?? "$"
        return local.count == 1 ? local : "$"
    }

    static var currencyAlternates: [String] {
        ["$", "₹", "€", "£", "¥", "₩", "¢", "₽"].filter { $0 != currency }
    }

    static let symbolAlternates: [String: [String]] = [
        "0": ["°"], "-": ["–", "—", "•"], "/": ["\\"], "&": ["§"], "\"": ["“", "”", "„", "»", "«"],
        ".": ["…"], "?": ["¿"], "!": ["¡"], "'": ["‘", "’", "`"], "%": ["‰"],
    ]

    static func rows(page: KeyPage, layout: KeyboardLetterLayout, field: FieldTraits, numberRow: Bool) -> [[KeySpec]] {
        if page == .digits || (field.isDigitPad && page == .letters) { return digitRows(field) }
        var rows: [[KeySpec]]
        switch page {
        case .letters:
            var letters = letterRows(layout).map { row in
                row.map { KeySpec(action: .insert(String($0)), label: String($0), alternates: accents[$0] ?? []) }
            }
            // Without a number row, holding a top-row letter types its digit.
            if !numberRow, letters[0].count == 10 {
                for (i, digit) in "1234567890".enumerated() {
                    letters[0][i].alternates.insert(String(digit), at: 0)
                    letters[0][i].hint = String(digit)
                }
            }
            rows = numberRow ? ["1234567890".map { KeySpec(action: .insert(String($0)), label: String($0), alternates: symbolAlternates[String($0)] ?? []) }] : []
            rows += [letters[0], letters[1],
                    [KeySpec(action: .shift, label: "shift", width: .units(1.4))] + letters[2]
                        + [KeySpec(action: .delete, label: "delete", width: .units(1.4))]]
        case .numbers, .symbols:
            let top = page == .numbers ? "1234567890" : "[]{}#%^*+="
            let middle = page == .numbers ? ["-", "/", ":", ";", "(", ")", currency, "&", "@", "\""]
                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
            func key(_ s: String) -> KeySpec {
                KeySpec(action: .insert(s), label: s,
                        alternates: s == currency ? currencyAlternates : (symbolAlternates[s] ?? []))
            }
            let toggle = page == .numbers ? KeySpec(action: .page(.symbols), label: "#+=", width: .units(1.4))
                : KeySpec(action: .page(.numbers), label: "123", width: .units(1.4))
            let numpad = KeySpec(action: .page(.numpad), label: "numpad", width: .units(1.4))
            rows = [top.map { key(String($0)) }, middle.map(key),
                    // The punctuation shares the row, so it spans the width like the digits above.
                    [toggle, numpad] + [".", ",", "?", "!", "'"].map { var k = key($0); k.width = .flexible; return k }
                        + [KeySpec(action: .delete, label: "delete", width: .units(1.4))]]
        case .digits:
            return digitRows(field)
        case .numpad:
            return numpadRows(field)
        }
        rows.append(bottomRow(page: page, field: field))
        return rows
    }

    private static func bottomRow(page: KeyPage, field: FieldTraits) -> [KeySpec] {
        var row = [page == .letters ? KeySpec(action: .page(.numbers), label: "123", width: .units(1.4))
                   : KeySpec(action: .page(.letters), label: "ABC", width: .units(1.4))]
        if field.showsGlobe { row.append(KeySpec(action: .globe, label: "globe", width: .units(1.4))) }
        row.append(KeySpec(action: .emoji, label: "emoji", width: .units(1.4)))
        switch field.keyboardType {
        case .emailAddress:
            row.append(KeySpec(action: .insert("@"), label: "@"))
            row.append(KeySpec(action: .space, label: "space", width: .flexible))
            row.append(KeySpec(action: .insert("."), label: ".", alternates: domains))
        case .URL:
            // Only URL fields: in search fields (Safari's address bar) a
            // period beside the space bar is hit instead of space.
            row.append(KeySpec(action: .space, label: "space", width: .flexible))
            row.append(KeySpec(action: .insert("."), label: ".", alternates: domains))
            row.append(KeySpec(action: .insert("/"), label: "/"))
        default:
            row.append(KeySpec(action: .space, label: "space", width: .flexible))
        }
        row.append(KeySpec(action: .returnKey, label: field.returnLabel, width: .units(2.2)))
        return row
    }

    static let domains = [".com", ".net", ".org", ".edu", ".in", ".co"]

    /// A calculator-style pad for text fields: digits in a 3×3 grid with 0
    /// below, and a column for minus, space, delete and return. ABC goes back
    /// to letters; the pad stays up after space and return.
    private static func numpadRows(_ field: FieldTraits) -> [[KeySpec]] {
        func key(_ s: String, alternates: [String] = []) -> KeySpec {
            KeySpec(action: .insert(s), label: s, alternates: alternates, width: .flexible)
        }
        let separator = Locale.current.decimalSeparator ?? "."
        return [["1", "2", "3"].map { key($0) } + [key("-", alternates: ["+", "*", "/", "=", "%"])],
                ["4", "5", "6"].map { key($0) } + [KeySpec(action: .space, label: "space", width: .flexible)],
                ["7", "8", "9"].map { key($0) } + [KeySpec(action: .delete, label: "delete", width: .flexible)],
                [KeySpec(action: .page(.letters), label: "ABC", width: .flexible), key("0"),
                 key(separator, alternates: [separator == "." ? "," : "."]),
                 KeySpec(action: .returnKey, label: field.returnLabel, width: .flexible)]]
    }

    /// iOS's number pads: digits without letters, and a flat corner key and
    /// delete. Where the system draws no globe, the corner holds it, beside
    /// the decimal separator on a decimal pad.
    private static func digitRows(_ field: FieldTraits) -> [[KeySpec]] {
        func digit(_ d: String) -> KeySpec { KeySpec(action: .insert(d), label: d, width: .flexible) }
        func plain(_ action: KeyAction, _ label: String, alternates: [String] = [], width: KeySpec.Width) -> KeySpec {
            KeySpec(action: action, label: label, alternates: alternates, width: width, plain: true)
        }
        let symbol: KeySpec?
        switch field.keyboardType {
        case .decimalPad:
            let separator = Locale.current.decimalSeparator ?? "."
            symbol = plain(.insert(separator), separator, width: .flexible)
        case .phonePad: symbol = plain(.insert("+"), "+ * #", alternates: ["*", "#", ","], width: .flexible)
        default: symbol = nil
        }
        let corner: [KeySpec]
        switch (field.showsGlobe, symbol) {
        case (true, var symbol?):
            symbol.width = .share(0.5)
            corner = [plain(.globe, "globe", width: .share(0.5)), symbol]
        case (true, nil): corner = [plain(.globe, "globe", width: .flexible)]
        case (false, let symbol?): corner = [symbol]
        case (false, nil): corner = [KeySpec(action: .page(.letters), label: "", width: .flexible)]
        }
        return [["1", "2", "3"].map(digit), ["4", "5", "6"].map(digit), ["7", "8", "9"].map(digit),
                corner + [digit("0"), plain(.delete, "delete", width: .flexible)]]
    }
}
