import SwiftUI
import UIKit

/// The mini keyboard under the mic bar: the edit key and the most used
/// punctuation, or the digits after 123, then emoji, the size toggle, space
/// and return.
struct MiniKeys: View {
    @ObservedObject var typing: TypingController
    let showsGlobe: Bool
    weak var controller: KeyboardViewController?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                if typing.miniDigits {
                    ForEach(Array("1234567890"), id: \.self) { digit in
                        KeyCap(title: String(digit)) { typing.insert(String(digit)) }
                    }
                } else {
                    KeyCap(systemImage: "character.cursor.ibeam", label: "Edit") { typing.showsEdit = true }
                        .frame(width: 46)
                    ForEach(["@", ".", ",", "?", "!", "'"], id: \.self) { mark in
                        KeyCap(title: mark) { typing.insert(mark) }
                    }
                }
                RepeatingKey { typing.deleteFromPanel() }.frame(width: 46)
            }
            HStack(spacing: 5) {
                KeyCap(title: typing.miniDigits ? "@?!" : "123") { typing.miniDigits.toggle() }
                    .frame(width: 46)
                if showsGlobe { GlobeKey(controller: controller).frame(width: 46) }
                KeyCap(systemImage: "face.smiling", label: "Emoji") { typing.showsEmoji = true }
                    .frame(width: 46)
                KeyCap(systemImage: "arrow.up.left.and.arrow.down.right", label: "Full Keyboard") { typing.toggleMini() }
                    .frame(width: 46)
                KeyCap(title: "space") { typing.insert(" ") }
                KeyCap(systemImage: "return", label: "Return") { typing.insert("\n") }
                    .frame(width: 76)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

/// Number, decimal and phone pads, where Hex's keys would type letters: digits,
/// the pad's symbol, and delete.
struct DigitPad: View {
    @ObservedObject var typing: TypingController
    let showsGlobe: Bool
    weak var controller: KeyboardViewController?

    private var symbol: String? {
        switch typing.proxy?.keyboardType {
        case .decimalPad: return Locale.current.decimalSeparator ?? "."
        case .phonePad, .namePhonePad: return "+"
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(["123", "456", "789"], id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(Array(row), id: \.self) { digit in
                        KeyCap(title: String(digit)) { typing.insert(String(digit)) }
                    }
                }
            }
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    if showsGlobe { GlobeKey(controller: controller) }
                    if let symbol { KeyCap(title: symbol) { typing.insert(symbol) } }
                    if !showsGlobe, symbol == nil { Color.clear }
                }
                KeyCap(title: "0") { typing.insert("0") }
                RepeatingKey { typing.deleteFromPanel() }
            }
        }
        .padding(6)
    }
}
