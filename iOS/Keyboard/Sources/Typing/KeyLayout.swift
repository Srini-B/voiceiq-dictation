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
}

struct KeySpec: Equatable {
    enum Width: Equatable {
        /// One letter key.
        case unit
        /// A multiple of a letter key.
        case units(CGFloat)
        /// Shares what the row has left: the space bar.
        case flexible
    }
    var action: KeyAction
    var label: String
    var alternates: [String] = []
    var width: Width = .unit

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

    static func rows(page: KeyPage, layout: KeyboardLetterLayout, field: FieldTraits) -> [[KeySpec]] {
        if page == .digits || (field.isDigitPad && page == .letters) { return digitRows(field) }
        var rows: [[KeySpec]]
        switch page {
        case .letters:
            let letters = letterRows(layout).map { row in
                row.map { KeySpec(action: .insert(String($0)), label: String($0), alternates: accents[$0] ?? []) }
            }
            rows = [letters[0], letters[1],
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
            rows = [top.map { key(String($0)) }, middle.map(key),
                    [toggle] + [".", ",", "?", "!", "'"].map { var k = key($0); k.width = .units(1.4); return k }
                        + [KeySpec(action: .delete, label: "delete", width: .units(1.4))]]
        case .digits:
            return digitRows(field)
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
        case .URL, .webSearch:
            row.append(KeySpec(action: .space, label: "space", width: .flexible))
            row.append(KeySpec(action: .insert("."), label: ".", alternates: domains))
            if field.keyboardType == .URL { row.append(KeySpec(action: .insert("/"), label: "/")) }
        default:
            row.append(KeySpec(action: .space, label: "space", width: .flexible))
        }
        row.append(KeySpec(action: .returnKey, label: field.returnLabel, width: .units(2.2)))
        return row
    }

    static let domains = [".com", ".net", ".org", ".edu", ".in", ".co"]

    private static func digitRows(_ field: FieldTraits) -> [[KeySpec]] {
        func digit(_ d: String) -> KeySpec { KeySpec(action: .insert(d), label: d, width: .flexible) }
        let corner: KeySpec
        switch field.keyboardType {
        case .decimalPad: corner = digit(Locale.current.decimalSeparator ?? ".")
        case .phonePad: corner = KeySpec(action: .insert("+"), label: "+ * #", alternates: ["*", "#", ","], width: .flexible)
        default: corner = KeySpec(action: .page(.letters), label: "", width: .flexible)
        }
        return [["1", "2", "3"].map(digit), ["4", "5", "6"].map(digit), ["7", "8", "9"].map(digit),
                [corner, digit("0"), KeySpec(action: .delete, label: "delete", width: .flexible)]]
    }
}
