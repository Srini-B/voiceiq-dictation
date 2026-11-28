import Foundation

/// Where a draft sits in a field's text, in UTF-16 units (the unit
/// Accessibility and UIKit report ranges in), and the exact text it holds.
/// A draft is replaced only while that exact text is still there: an edit
/// inside it, a deletion, or a copy that can't be told apart from it leaves
/// it alone, so the user's own text is never written over.
public struct DraftSpan: Equatable, Sendable {
    public var location: Int
    public var text: String

    public init(location: Int, text: String) {
        self.location = location
        self.text = text
    }

    public var length: Int { text.utf16.count }
    public var end: Int { location + length }

    /// The draft in `value` now: at its own place when the text there is
    /// still the draft, otherwise at the one place it occurs (the user typed
    /// or deleted before it). Nil when it was edited, deleted, or occurs more
    /// than once away from its place.
    public func located(in value: String) -> DraftSpan? {
        guard !text.isEmpty else { return nil }
        let units = Array(value.utf16), draft = Array(text.utf16)
        func holds(at offset: Int) -> Bool {
            offset >= 0 && offset + draft.count <= units.count
                && units[offset..<(offset + draft.count)].elementsEqual(draft)
        }
        if holds(at: location) { return self }
        var found: Int?
        var offset = 0
        while offset + draft.count <= units.count {
            if holds(at: offset) {
                guard found == nil else { return nil }
                found = offset
            }
            offset += 1
        }
        return found.map { DraftSpan(location: $0, text: text) }
    }

    /// `value` with the draft replaced by `replacement`. Nil when the draft
    /// does not fit `value` at its location.
    public func replacing(in value: String, with replacement: String) -> String? {
        var units = Array(value.utf16)
        guard location >= 0, end <= units.count,
              units[location..<end].elementsEqual(text.utf16) else { return nil }
        units.replaceSubrange(location..<end, with: Array(replacement.utf16))
        return String(decoding: units, as: UTF16.self)
    }

    /// The selection after the draft became `replacementLength` units long:
    /// one before the draft stays, one after it moves with it, and one that
    /// touched it goes to the end of the new text.
    public func selection(_ selection: (location: Int, length: Int), afterReplacingWith replacementLength: Int)
        -> (location: Int, length: Int) {
        if selection.location + selection.length <= location {
            return selection
        }
        if selection.location >= end {
            return (selection.location + replacementLength - length, selection.length)
        }
        return (location + replacementLength, 0)
    }

    /// The text around the draft, with the draft taken out, for fitting the
    /// written text where the draft was.
    public func surrounding(in value: String) -> SurroundingText? {
        guard let without = replacing(in: value, with: "") else { return nil }
        return SurroundingText(value: without, selectionLocation: location, selectionLength: 0)
    }
}
