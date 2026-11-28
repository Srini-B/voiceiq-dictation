#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import VoiceIQBridge

/// What the app draws over the target field while a draft is in it: a
/// spinner at the cursor until the transcript lands, then a line under it.
/// Rects are in AppKit screen coordinates.
@MainActor
public protocol DraftMarking: AnyObject {
    func showSpinner(at caret: CGRect)
    func underline(_ lines: [CGRect])
    func clear()
}

/// The Mac's draft: the transcript goes in through the usual ladder, is
/// found again by Accessibility, underlined, and swapped for the written text
/// by selecting exactly its range and writing over it.
///
/// Only fields that say what they hold and where their cursor is take a
/// draft (`begin` returns nil otherwise, and the dictation pastes once as
/// before): terminals, typed-in apps, unreadable fields such as Google Docs'
/// canvas, Press Return after paste, and secure input all keep the single
/// paste. Every draft in a field is followed through each change to it
/// (`DraftLedger`, one per field, `DraftField`): each dictation swaps only
/// its own range, so earlier dictations' text, written or still a draft,
/// and anything the user typed are never written over, and an edit inside
/// a draft makes it the user's text. Writes to one field take turns. The
/// selection is set and read back before anything is written, and a ⌘V
/// goes only to the focused field. AGIHunt/blurt (MIT) replaces a
/// pasted dictation the same way; this is our own implementation.
@MainActor
public final class FieldDraft: TextDraft {
    private let element: AXUIElement
    private let context: DictationContext
    private let inserter: InsertionCoordinator
    private let marks: DraftMarking
    /// Chromium and Electron fields can report an Accessibility write that
    /// never happened, or a stale value after one that did; their swap is a
    /// verified selection plus ⌘V.
    private let usesPasteOnly: Bool
    private let id = UUID()
    private var field: DraftField?
    /// The text this dictation left in the field, once shown.
    private var landed: String?
    private var tracking: Task<Void, Never>?
    private var ended = false

    /// How long a pasted draft may take to show in the field's value.
    static let landingWait: TimeInterval = 1.5
    /// How often the underline follows the text while the writer runs.
    static let trackingInterval: TimeInterval = 0.15
    /// Underlines for longer drafts would mean dozens of windows.
    static let maxLines = 30

    private init(element: AXUIElement, context: DictationContext, inserter: InsertionCoordinator,
                 marks: DraftMarking, usesPasteOnly: Bool) {
        self.element = element
        self.context = context
        self.inserter = inserter
        self.marks = marks
        self.usesPasteOnly = usesPasteOnly
    }

    /// A draft for the focused field when it can hold one, with the spinner
    /// at its cursor; nil otherwise.
    public static func begin(context: DictationContext, inserter: InsertionCoordinator,
                             marks: DraftMarking) -> FieldDraft? {
        guard !SecureInput.isActive, !ReturnAfterPaste.isWanted(for: context) else { return nil }
        let bundleID = context.targetAppBundleID
        if let bundleID, AppQuirks.forcePaste.contains(bundleID) { return nil }
        let bundleURL = context.targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL }
        guard TypingInserter.mode(bundleID: bundleID, bundleURL: bundleURL) == nil else { return nil }
        guard let element = focusedTarget(context: context), let reading = PasteCheck.reading(of: element) else {
            return nil
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String, role == "AXSecureTextField" || AXInserter.rolesWithoutText.contains(role) {
            return nil
        }
        let draft = FieldDraft(element: element, context: context, inserter: inserter, marks: marks,
                               usesPasteOnly: bundleID.map(AppQuirks.needsManualAccessibility.contains) ?? false)
        if let caret = caretRect(in: element, at: reading.caret) { marks.showSpinner(at: caret) }
        return draft
    }

    public func show(_ text: String) async -> DraftShown {
        guard !ended else { return .notInserted }
        let field = DraftField.open(element)
        self.field = field
        await field.acquire()
        defer { field.release() }
        guard !ended, Self.focusedTarget(context: context).map({ CFEqual($0, element) }) == true,
              let before = field.sync() else {
            marks.clear()
            return .notInserted
        }
        let fitted = InsertionCoordinator.fitted(text, context: context)
        guard await inserter.insert(fitted, context: context) == .inserted else {
            marks.clear()
            return .notInserted
        }
        // A paste lands when the app gets to it; Accessibility catches up
        // after that. Only exactly this insert counts as the draft.
        let deadline = Date().addingTimeInterval(Self.landingWait)
        var changed = false
        while true {
            if let now = PasteCheck.reading(of: element), now.value != field.ledger.value {
                changed = true
                if let span = field.ledger.add(id, text: fitted, at: before.caret, over: before.selectionLength,
                                               landedIn: now.value) {
                    landed = span.text
                    break
                }
            }
            guard Date() < deadline, !ended else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard landed != nil else {
            marks.clear()
            // Nothing changed: nothing went in, so the written text may.
            if !changed { return .notInserted }
            Log.insertion.info("draft: went in but not as one exact insert — it stays")
            return .lost
        }
        guard !ended else { return .shown }
        drawUnderline()
        tracking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.trackingInterval))
                self?.follow()
            }
        }
        return .shown
    }

    public func replace(with text: String) async -> Bool {
        tracking?.cancel()
        defer { marks.clear() }
        guard let field, landed != nil else { return false }
        await field.acquire()
        defer { field.release() }
        // The draft's own paste may still be restoring the clipboard. Wait it
        // out now, so every check below holds when the ⌘V is posted.
        await inserter.finishPendingPaste()
        guard let reading = field.sync(), let span = field.ledger.draft(id) else {
            Log.insertion.info("draft: edited or gone — kept as it was")
            return false
        }
        let written = span.surrounding(in: reading.value)?.fitted(text) ?? text
        guard written != span.text else { return true }
        guard let expected = span.replacing(in: reading.value, with: written) else { return false }
        let selection = span.selection((reading.caret, reading.selectionLength),
                                       afterReplacingWith: written.utf16.count)
        func swapped(_ now: PasteCheck.Reading) -> Bool {
            field.ledger.replace(id, with: written, landedIn: now.value)
            landed = written
            if now.value == expected {
                _ = select(selection.location, selection.length)
            } else {
                Log.insertion.info("draft: replaced, and the app adjusted the text")
            }
            return true
        }
        guard select(span.location, span.length) else {
            _ = select(reading.caret, reading.selectionLength)
            Log.insertion.info("draft: the field didn't take the selection — kept as it was")
            return false
        }
        if !usesPasteOnly,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, written as CFTypeRef) == .success {
            for _ in 0..<4 {
                if let now = PasteCheck.reading(of: element), now.value != reading.value { return swapped(now) }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        // ⌘V goes to the focused field only, and only while the draft is
        // still exactly what is selected.
        guard Self.focusedTarget(context: context).map({ CFEqual($0, element) }) == true,
              let selected = PasteCheck.reading(of: element), selected.value == reading.value,
              selected.caret == span.location, selected.selectionLength == span.length else {
            _ = select(reading.caret, reading.selectionLength)
            Log.insertion.info("draft: not focused or the selection moved — kept as it was")
            return false
        }
        guard await inserter.paste(written) else {
            _ = select(reading.caret, reading.selectionLength)
            return false
        }
        let deadline = Date().addingTimeInterval(Self.landingWait)
        while Date() < deadline {
            if let now = PasteCheck.reading(of: element), now.value != reading.value { return swapped(now) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Log.insertion.info("draft: the paste over it never showed — kept as it was")
        return false
    }

    /// The text this dictation left in the field: the written text after a
    /// swap, else the draft.
    public var text: String? { landed }

    public func end() {
        ended = true
        tracking?.cancel()
        marks.clear()
        field?.forget(id)
    }

    // MARK: - Field geometry

    /// The underline follows the draft as the user types around it, and
    /// goes when the draft can no longer be found.
    private func follow() {
        guard !ended, let field, !field.isBusy else { return }
        _ = field.sync()
        drawUnderline()
    }

    private func drawUnderline() {
        guard let span = field?.ledger.draft(id) else { return marks.underline([]) }
        marks.underline(Self.lineRects(in: element, location: span.location, length: span.length))
    }

    private func select(_ location: Int, _ length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
              let now = PasteCheck.reading(of: element) else { return false }
        return now.caret == location && now.selectionLength == length
    }

    /// The focused element when it belongs to the frontmost target app and
    /// is the field the dictation started in.
    private static func focusedTarget(context: DictationContext) -> AXUIElement? {
        guard let pid = context.targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        if let start = context.focusedField?.element, !CFEqual(start as CFTypeRef, element) { return nil }
        return element
    }

    static func caretRect(in element: AXUIElement, at caret: Int) -> CGRect? {
        if let rect = bounds(in: element, location: caret, length: 0), rect.height > 1 {
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        if caret > 0, let rect = bounds(in: element, location: caret - 1, length: 1), rect.height > 1 {
            return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        return nil
    }

    /// One rect per line the range covers, from the field's line ranges;
    /// a single rect when the field has no line attributes and the range
    /// fits on one line; none otherwise.
    static func lineRects(in element: AXUIElement, location: Int, length: Int) -> [CGRect] {
        guard length > 0 else { return [] }
        let end = location + length
        if let first = line(in: element, at: location), let last = line(in: element, at: end - 1), last >= first {
            var rects: [CGRect] = []
            for number in first...min(last, first + maxLines - 1) {
                guard let lineRange = range(in: element, line: number) else { continue }
                let start = max(location, lineRange.location), stop = min(end, lineRange.location + lineRange.length)
                guard stop > start, let rect = bounds(in: element, location: start, length: stop - start),
                      rect.width >= 1 else { continue }
                rects.append(rect)
            }
            if !rects.isEmpty { return rects }
        }
        guard let whole = bounds(in: element, location: location, length: length), whole.width >= 1,
              let oneLine = caretRect(in: element, at: location), whole.height < oneLine.height * 1.6 else { return [] }
        return [whole]
    }

    /// `kAXBoundsForRangeParameterizedAttribute`, flipped from the top-left
    /// screen origin Accessibility uses to AppKit's bottom-left one.
    static func bounds(in element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func line(in element: AXUIElement, at index: Int) -> Int? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXLineForIndexParameterizedAttribute as CFString,
                                                         index as CFNumber, &out) == .success else { return nil }
        return out as? Int
    }

    private static func range(in element: AXUIElement, line: Int) -> CFRange? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForLineParameterizedAttribute as CFString,
                                                         line as CFNumber, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(out as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}
/// One field's drafts, shared by the dictations that have one in it, and
/// a turn for writing to it: one dictation's selection must never take
/// another's paste.
@MainActor
final class DraftField {
    let element: AXUIElement
    var ledger: DraftLedger
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static var fields: [DraftField] = []

    private init(element: AXUIElement, value: String) {
        self.element = element
        self.ledger = DraftLedger(value: value)
    }

    /// The field's ledger, made when its first draft starts.
    static func open(_ element: AXUIElement) -> DraftField {
        if let field = fields.first(where: { CFEqual($0.element, element) }) { return field }
        let field = DraftField(element: element, value: PasteCheck.reading(of: element)?.value ?? "")
        fields.append(field)
        return field
    }

    /// Reads the field and follows the drafts through what changed.
    func sync() -> PasteCheck.Reading? {
        guard let reading = PasteCheck.reading(of: element) else { return nil }
        ledger.observe(reading.value)
        return reading
    }

    var isBusy: Bool { locked }

    func acquire() async {
        guard locked else { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    /// A dictation is done with its draft; a field with none left is closed.
    func forget(_ id: UUID) {
        ledger.remove(id)
        if ledger.drafts.isEmpty, !locked { Self.fields.removeAll { $0 === self } }
    }
}
#endif
