import Foundation

/// Where a draft sits in a field's text, in UTF-16 units (the unit
/// Accessibility and UIKit report ranges in), and the exact text it holds.
public struct DraftSpan: Equatable, Sendable {
    public var location: Int
    public var text: String

    public init(location: Int, text: String) {
        self.location = location
        self.text = text
    }

    public var length: Int { text.utf16.count }
    public var end: Int { location + length }

    /// Whether `value` holds exactly the draft at its location.
    public func isIntact(in value: String) -> Bool {
        replacing(in: value, with: "") != nil
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
        if selection.location + selection.length <= location { return selection }
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

/// The one contiguous change that turns `old` into `new`: the longest
/// common start and end are kept, the rest is the edit. Two changes in far
/// apart places read as one edit spanning both, which only ever makes a
/// draft between them count as touched.
public struct FieldEdit: Equatable, Sendable {
    public var location: Int
    public var removed: Int
    public var inserted: String

    public init(location: Int, removed: Int, inserted: String) {
        self.location = location
        self.removed = removed
        self.inserted = inserted
        earliest = location
    }

    public init?(from old: String, to new: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        location = prefix
        removed = a.count - prefix - suffix
        inserted = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        // The same change read from the end first: with repeated text
        // ("Hello Hello " → "Hello ") it can sit further left, and which
        // copy changed can't be told.
        var endFirst = 0
        while endFirst < a.count, endFirst < b.count, a[a.count - 1 - endFirst] == b[b.count - 1 - endFirst] {
            endFirst += 1
        }
        earliest = max(0, min(prefix, a.count - endFirst - removed))
    }

    /// The leftmost place the same change could have been made; equal to
    /// `location` when the change can only be in one place.
    public var earliest: Int

    public var insertedLength: Int { inserted.utf16.count }
}

/// Every draft in one field, followed through each change to the field. A
/// draft is one dictation's own text: an edit before it moves it, an edit
/// after it leaves it, and an edit that touches it makes it the user's
/// text, so it is dropped and never replaced. Each dictation swaps only its
/// own draft; earlier dictations' text, already written or still a draft,
/// and anything the user typed are never written over.
public struct DraftLedger: Equatable, Sendable {
    public private(set) var value: String
    public private(set) var drafts: [UUID: DraftSpan] = [:]

    public init(value: String) {
        self.value = value
    }

    /// The field now reads `new`, changed by someone else (the user, the
    /// app): the change is read as one edit (`FieldEdit`).
    public mutating func observe(_ new: String) {
        guard let edit = FieldEdit(from: value, to: new) else { return }
        apply(edit, giving: new)
    }

    /// This dictation put `text` in at `location`, over `selected` units,
    /// and the field now reads `new`. The draft is recorded only when that
    /// is exactly the change; otherwise the change is read as someone else's
    /// and nil is returned.
    public mutating func add(_ id: UUID, text: String, at location: Int, over selected: Int,
                             landedIn new: String) -> DraftSpan? {
        guard !text.isEmpty, location >= 0, selected >= 0, value.utf16.count >= location + selected,
              DraftSpan(location: location, text: Self.slice(value, location, selected)).replacing(in: value, with: text) == new
        else {
            observe(new)
            return nil
        }
        apply(FieldEdit(location: location, removed: selected, inserted: text), giving: new)
        let added = DraftSpan(location: location, text: text)
        drafts[id] = added
        return added
    }

    /// This dictation's draft became `written` and the field now reads
    /// `new`. The other drafts move by exactly that change, so the swap of
    /// one dictation never shifts another onto the wrong text. When the
    /// field reads something else (the app adjusted the text), the change is
    /// read as an edit like any other.
    public mutating func replace(_ id: UUID, with written: String, landedIn new: String) {
        guard let span = drafts.removeValue(forKey: id) else { return observe(new) }
        if span.replacing(in: value, with: written) == new {
            apply(FieldEdit(location: span.location, removed: span.length, inserted: written), giving: new)
        } else {
            observe(new)
        }
    }

    private mutating func apply(_ edit: FieldEdit, giving new: String) {
        value = new
        let editEnd = edit.location + edit.removed
        for (id, span) in drafts {
            var moved = span
            // The change could be anywhere from `earliest` to its end: a
            // draft in that stretch may be the copy that changed.
            if edit.earliest < edit.location, span.location < editEnd, span.end > edit.earliest {
                drafts[id] = nil
                continue
            }
            if editEnd <= span.location {
                // Wholly before it; an insert at its first character counts as before.
                moved.location += edit.insertedLength - edit.removed
            } else if edit.location < span.end {
                // It touched the draft: the text is the user's now.
                drafts[id] = nil
                continue
            }
            drafts[id] = moved.isIntact(in: new) ? moved : nil
        }
    }

    private static func slice(_ value: String, _ location: Int, _ length: Int) -> String {
        let units = Array(value.utf16)
        return String(decoding: units[location..<(location + length)], as: UTF16.self)
    }

    /// This dictation's draft, if it is still exactly there.
    public func draft(_ id: UUID) -> DraftSpan? { drafts[id] }

    /// Forgets a draft: swapped, kept, or ended.
    public mutating func remove(_ id: UUID) {
        drafts[id] = nil
    }
}
