import UIKit

/// A text field and the keyboard's view of it, which can disagree, as
/// measured in the iOS 27 Simulator (Messages, its search field, a SwiftUI
/// text field, 2026-11-28; `activities/2026-11-28-iphone-draft-swap-by-insert.md`).
///
/// `string` is the host's text. The host gets the calls of one turn as one
/// batch (`endTurn`) and applies its insertions, deletions and cursor moves
/// first, then new marked text, then `unmarkText`, whatever order they were
/// called in. An insert or new marked text replaces marked text; Delete on
/// marked text removes all of it.
///
/// What the proxy answers comes from a copy the keyboard's process edits
/// call by call: it leaves marked text out of the context until it is
/// unmarked, and Delete takes one character from it. The host sends its own
/// text only after a change made on its side (`hostDid`), never after the
/// keyboard's writes, so after a batch the host applied differently the copy
/// shows a field that isn't there.
final class HostField: NSObject, UITextDocumentProxy {
    private struct Text {
        var characters: [Character]
        var cursor: Int
        var selected = 0
        var marked: Range<Int>?

        mutating func insert(_ string: String) {
            let range = marked ?? cursor..<(cursor + selected)
            characters.replaceSubrange(range, with: string)
            cursor = range.lowerBound + string.count
            selected = 0
            marked = nil
        }

        mutating func mark(_ string: String) {
            let range = marked ?? cursor..<(cursor + selected)
            characters.replaceSubrange(range, with: string)
            marked = string.isEmpty ? nil : range.lowerBound..<(range.lowerBound + string.count)
            cursor = range.lowerBound + string.count
            selected = 0
        }

        mutating func deleteOne() {
            marked = nil
            if selected > 0 {
                characters.removeSubrange(cursor..<(cursor + selected))
                selected = 0
            } else if cursor > 0 {
                characters.remove(at: cursor - 1)
                cursor -= 1
            }
        }

        mutating func deleteAsHost() {
            guard let range = marked else { return deleteOne() }
            characters.removeSubrange(range)
            cursor = range.lowerBound
            marked = nil
        }

        mutating func move(by offset: Int) {
            marked = nil
            cursor = min(max((offset < 0 ? cursor : cursor + selected) + offset, 0), characters.count)
            selected = 0
        }

        var before: String {
            guard let marked, marked.upperBound <= cursor else { return String(characters[..<cursor]) }
            return String(characters[..<marked.lowerBound]) + String(characters[marked.upperBound..<cursor])
        }
    }

    private enum Edit {
        case insert(String)
        case delete
        case move(Int)
    }

    private var host: Text
    private var copy: Text
    private var edits: [Edit] = []
    private var unmarks = false
    private var marks: String?

    init(_ text: String) {
        host = Text(characters: Array(text), cursor: text.count)
        copy = host
    }

    /// The host's text, as the user sees it.
    var string: String { String(host.characters) }
    /// The host's marked text, which it draws underlined.
    var marked: String? { host.marked.map { String(host.characters[$0]) } }
    /// A host that makes marked text plain as soon as it gets it, without
    /// telling the keyboard (a field that rewrites its text on every change).
    var commitsMarkedText = false

    /// The run loop turn ends: the host gets the keyboard's calls of this turn.
    func endTurn() {
        for edit in edits {
            switch edit {
            case .insert(let string): host.insert(string)
            case .delete: host.deleteAsHost()
            case .move(let offset): host.move(by: offset)
            }
        }
        if let marks { host.mark(marks) }
        if unmarks { host.marked = nil }
        if commitsMarkedText { host.marked = nil }
        edits = []
        unmarks = false
        marks = nil
    }

    /// The user or the host changes the field without the keyboard. The host
    /// then reports its text, marked text included, and the copy is that text.
    func hostDid(_ change: (HostField) -> Void) {
        endTurn()
        change(self)
        copy = host
        copy.marked = nil
    }

    /// For `hostDid`: the user selects the last occurrence of `word`.
    func select(_ word: String) {
        guard let range = string.range(of: word, options: .backwards) else { return }
        host.cursor = string.distance(from: string.startIndex, to: range.lowerBound)
        host.selected = word.count
        host.marked = nil
    }

    /// For `hostDid`: Send. The field is empty afterwards.
    func send() {
        host = Text(characters: [], cursor: 0)
    }

    // MARK: - UITextDocumentProxy, answered from the copy

    var documentContextBeforeInput: String? { copy.before }
    var documentContextAfterInput: String? { String(copy.characters[(copy.cursor + copy.selected)...]) }
    var selectedText: String? {
        copy.selected > 0 ? String(copy.characters[copy.cursor..<(copy.cursor + copy.selected)]) : nil
    }
    var documentInputMode: UITextInputMode? { nil }
    let documentIdentifier = UUID()
    var hasText: Bool { !copy.characters.isEmpty }

    func insertText(_ text: String) {
        copy.insert(text)
        edits.append(.insert(text))
    }

    func deleteBackward() {
        copy.deleteOne()
        edits.append(.delete)
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        copy.move(by: offset)
        edits.append(.move(offset))
    }

    func setMarkedText(_ markedText: String, selectedRange: NSRange) {
        copy.mark(markedText)
        marks = markedText
    }

    func unmarkText() {
        copy.marked = nil
        unmarks = true
    }
}
