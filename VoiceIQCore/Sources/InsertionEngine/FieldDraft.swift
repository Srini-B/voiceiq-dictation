#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import VoiceIQBridge

/// The spinner's size in points, shared with the app's overlay.
public enum DraftOverlaySize {
    public static let spinner: CGFloat = 16
}

/// What the app draws over the target field while a draft is in it: a
/// spinner at the cursor until the transcript lands, then a line under it.
/// Rects are in AppKit screen coordinates, already kept inside the field.
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
    /// verified selection plus ⌘V. So is the swap in any field the draft
    /// itself went into by paste.
    private var usesPasteOnly: Bool
    /// Apps whose field showed nothing of a posted draft: they get no more
    /// drafts until VoiceiQ restarts.
    private static var noDraftApps: Set<String> = []
    /// Apps where a draft went in but didn't read as one exact insert.
    private static var misreadApps: Set<String> = []
    private let id = UUID()
    private var field: DraftField?
    /// The text this dictation left in the field, once shown.
    private var landed: String?
    /// The selected text the draft went in over, put back if the draft is
    /// taken out.
    private var replaced = ""

    private var tracking: Task<Void, Never>?
    private var ended = false
    /// Withdrawn before it went in (`stopShowing`).
    private var stopped = false

    /// How long a pasted draft may take to show in the field's value.
    static let landingWait: TimeInterval = 1.5
    /// How often the underline follows the text while the writer runs.
    static let trackingInterval: TimeInterval = 0.15
    /// Above this the field is read too often to follow its drafts cheaply
    /// (a long document); it keeps the single paste.
    static let maxFieldLength = 20_000
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
        if let app = appKey(context), noDraftApps.contains(app) { return nil }
        let bundleURL = context.targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL }
        guard TypingInserter.mode(bundleID: bundleID, bundleURL: bundleURL) == nil else { return nil }
        guard let element = focusedTarget(context: context), let reading = PasteCheck.reading(of: element),
              reading.value.utf16.count <= maxFieldLength else {
            return nil
        }
        var role: CFTypeRef?, subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String, role == "AXSecureTextField" || AXInserter.rolesWithoutText.contains(role) {
            return nil
        }
        // A password field is a text field whose subrole says so.
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == "AXSecureTextField" {
            return nil
        }
        let draft = FieldDraft(element: element, context: context, inserter: inserter, marks: marks,
                               usesPasteOnly: isChromiumOrElectron(bundleID: bundleID, bundleURL: bundleURL)
                                   || bundleID?.hasPrefix("com.apple.Safari") == true || isInWebArea(element))
        if let caret = caretRect(in: element, at: reading.caret, of: reading.value),
           let clip = visibleFrame(of: element), let spot = spinnerSpot(for: caret, in: clip) {
            marks.showSpinner(at: spot)
        }
        return draft
    }

    public func show(_ text: String) async -> DraftShown {
        guard !ended else { return .notInserted }
        let field = DraftField.open(element)
        self.field = field
        await field.acquire()
        defer { field.release() }
        // An earlier paste may still be restoring the clipboard; wait it out
        // before the checks, so an Esc during the wait stops this draft.
        await inserter.finishPendingPaste()
        guard !ended, !stopped, Self.focusedTarget(context: context).map({ CFEqual($0, element) }) == true,
              let before = field.sync() else {
            marks.clear()
            return .notInserted
        }
        let fitted = InsertionCoordinator.fitted(text, context: context)
        replaced = Self.slice(before.value, before.caret, before.selectionLength)
        // Nothing to show (a lone mark fitted away), or a selection of the
        // same text, which a paste would leave as it is and so can't be told
        // from a miss: the written text goes in alone.
        guard !fitted.isEmpty, replaced != fitted else {
            marks.clear()
            return .notInserted
        }
        // A withdraw while Accessibility was tried stops the paste after it.
        let insert = await inserter.insertReportingTier(fitted, context: context, announcesMiss: false,
                                                        stillWanted: { [weak self] in
                                                            self.map { !$0.stopped && !$0.ended } ?? false
                                                        })
        guard insert.outcome == .inserted else {
            marks.clear()
            // Withdrawn after Accessibility was tried: only a field read
            // unchanged for 0.5 s counts as untouched. A write that shows
            // late, or a field that can no longer be read, may hold the
            // draft, which then stays and is announced.
            if stopped {
                for _ in 0..<10 {
                    guard let now = PasteCheck.reading(of: element), now.value == before.value else { return .lost }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            return .notInserted
        }
        if !insert.byAccessibility { usesPasteOnly = true }
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
            if changed {
                // A field whose value doesn't read as the draft at the caret
                // (Chromium counts line breaks one way in its value and
                // another in its offsets) does it every time: a second time
                // in an app, it gets no more drafts.
                if let app = Self.appKey(context), !Self.misreadApps.insert(app).inserted {
                    Self.noDraftApps.insert(app)
                }
                Log.insertion.info("draft: went in but not as one exact insert — it stays")
                return .lost
            }
            // Nothing showed. Let the paste's own read-back finish (quiet for
            // a draft, so the raw text is never offered). Either way the app
            // gets no more drafts. A field still exactly as before after an
            // Accessibility write never took it, so the written text goes in
            // by the usual ladder; after a ⌘V, or a field that changed, the
            // paste may be there, so the written text never goes in beside it.
            await inserter.finishPendingPaste()
            if let now = PasteCheck.reading(of: element), now.value == before.value {
                if let app = Self.appKey(context) { Self.noDraftApps.insert(app) }
                // A field can take a paste and still read as before (a
                // terminal clears its input box once it passes the text on):
                // after a ⌘V the written text never goes in beside it.
                guard insert.byAccessibility else {
                    Log.insertion.info("draft: the field never showed the paste — it may be there; no more drafts in this app")
                    return .unseen
                }
                Log.insertion.info("draft: the field never showed the write — no more drafts in this app")
                return .notInserted
            }
            Log.insertion.info("draft: not seen in the field in time — the written text is in Paste last")
            return .lost
        }
        guard !ended else {
            // Ended while it landed: the ledger must not keep it.
            field.forget(id)
            return .shown
        }
        // An Accessibility insert doesn't scroll the field: a single-line
        // field would hide the draft past its right edge.
        await ScrollToCaret.ensureVisible(element, context: context)
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
        // The draft is selected for the swap: a key the user is typing
        // would replace it. Wait for a pause in typing, then read the field
        // as it is; through steady typing the draft stays as heard.
        guard await Self.typingPaused() else {
            Log.insertion.info("draft: the user is typing — kept as it was")
            return false
        }
        guard let reading = field.sync(), let span = field.ledger.draft(id) else {
            Log.insertion.info("draft: edited or gone — kept as it was")
            return false
        }
        // An empty text takes the draft out (`DraftStage.withdraw`): the
        // text it went in over comes back, selected as it was.
        let withdrawing = text.isEmpty
        let written = withdrawing ? replaced : span.surrounding(in: reading.value)?.fitted(text) ?? text
        guard written != span.text else { return true }
        // A field written only by ⌘V can't take the draft out: a Delete
        // posted over it would also delete a key the user typed meanwhile.
        if written.isEmpty, usesPasteOnly {
            Log.insertion.info("draft: no Accessibility write to take it out — kept as it was")
            return false
        }
        guard let expected = span.replacing(in: reading.value, with: written) else { return false }
        let following = Self.slice(reading.value, span.location + span.length,
                                   min(20, reading.value.utf16.count - span.location - span.length))
        let selection = withdrawing && !replaced.isEmpty
            ? (location: span.location, length: replaced.utf16.count)
            : span.selection((reading.caret, reading.selectionLength), afterReplacingWith: written.utf16.count)
        /// The field changed after the write: the swap only when the written
        /// text is where the draft was. A field that reads otherwise (the app
        /// adjusted the text, or a key typed over the selection) is followed
        /// as an edit, and the text in it is not tracked as ours.
        func swapped(_ now: PasteCheck.Reading) async -> Bool? {
            // Taken out (an empty written text) shows only as the exact result.
            // The written text, followed by what followed the draft: a key
            // typed over a draft the written text begins, or a host that
            // inserted beside it, reads otherwise.
            let end = written.utf16.count + span.location
            let placed = written.isEmpty ? now.value == expected
                : DraftSpan(location: span.location, text: written).isIntact(in: now.value)
                    && (following.isEmpty ? now.value.utf16.count == end
                                          : DraftSpan(location: end, text: following).isIntact(in: now.value))
            if placed {
                field.ledger.replace(id, with: written, landedIn: now.value)
                landed = written
                // Only over what the write left (a caret after the written
                // text, or the written text selected): a caret the user moved
                // since then stays where they put it.
                let leftByWrite = (now.caret == end && now.selectionLength == 0)
                    || (now.caret == span.location && now.selectionLength == written.utf16.count)
                if now.value == expected, leftByWrite {
                    _ = await select(selection.location, selection.length)
                }
                await ScrollToCaret.ensureVisible(element, context: context)
                return true
            }
            // Still the draft, selected: the write has not shown yet.
            if span.isIntact(in: now.value) { return nil }
            field.ledger.observe(now.value)
            landed = nil
            Log.insertion.info("draft: the field changed otherwise after the write — left as it is")
            return false
        }
        // The draft is selected and written only while its field is the
        // focused one; an unfocused field's refusal says nothing of the app.
        guard Self.focusedTarget(context: context).map({ CFEqual($0, element) }) == true else {
            Log.insertion.info("draft: its field is no longer focused — kept as it was")
            return false
        }
        /// Puts the user's selection back only while the field still shows
        /// the draft selected as this swap left it: a caret the user moved
        /// meanwhile stays where they put it.
        func restoreIfStillSelected() async {
            guard let now = PasteCheck.reading(of: element), now.value == reading.value,
                  now.caret == span.location, now.selectionLength == span.length else { return }
            _ = await select(reading.caret, reading.selectionLength)
        }
        // A password field took focus meanwhile: nothing is selected or
        // written while secure input is on.
        guard !SecureInput.isActive else {
            Log.insertion.info("draft: secure input is on — kept as it was")
            return false
        }
        guard await select(span.location, span.length, holding: reading.value) else {
            await restoreIfStillSelected()
            // Focused and unchanged, the field itself refused the selection.
            if Self.focusedTarget(context: context).map({ CFEqual($0, element) }) == true,
               PasteCheck.reading(of: element)?.value == reading.value { refusedByApp() }
            Log.insertion.info("draft: the field didn't take the selection — kept as it was")
            return false
        }
        if !usesPasteOnly,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, written as CFTypeRef) == .success {
            // An app that took the write may show it late; a ⌘V now could
            // put the text in twice. Wait for it, and never paste after it.
            let deadline = Date().addingTimeInterval(Self.landingWait)
            while Date() < deadline {
                if let now = PasteCheck.reading(of: element), now.value != reading.value,
                   let result = await swapped(now) { return result }
                try? await Task.sleep(for: .milliseconds(40))
            }
            await restoreIfStillSelected()
            if PasteCheck.reading(of: element)?.value == reading.value { refusedByApp() }
            Log.insertion.info("draft: the field took the write but never showed it — kept as it was")
            return false
        }
        // Another dictation's paste may have started meanwhile: wait it out
        // here, so `paste` posts right after the checks below.
        await inserter.finishPendingPaste()
        // ⌘V goes to the focused field only, and only while the draft is
        // still exactly what is selected.
        guard !SecureInput.isActive, Self.focusedTarget(context: context).map({ CFEqual($0, element) }) == true,
              let selected = PasteCheck.reading(of: element), selected.value == reading.value,
              selected.caret == span.location, selected.selectionLength == span.length,
              Self.selectedText(of: element).map({ $0 == span.text }) ?? true else {
            await restoreIfStillSelected()
            Log.insertion.info("draft: not focused, or the selection is not the draft — kept as it was")
            return false
        }
        guard await inserter.paste(written) else {
            await restoreIfStillSelected()
            return false
        }
        let deadline = Date().addingTimeInterval(Self.landingWait)
        while Date() < deadline {
            if let now = PasteCheck.reading(of: element), now.value != reading.value,
               let result = await swapped(now) { return result }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await restoreIfStillSelected()
        if PasteCheck.reading(of: element)?.value == reading.value { refusedByApp() }
        Log.insertion.info("draft: the paste over it never showed — kept as it was")
        return false
    }

    /// The field's own answer for what is selected: an Electron field can
    /// select a line break past the range it was asked for. Nil from a
    /// field that doesn't say, where the range read-back stands alone.
    private static func selectedText(of element: AXUIElement) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &out) == .success else {
            return nil
        }
        return out as? String
    }

    /// No key pressed for `typingPause`, waited for up to `typingWait`.
    /// Hardware keys only: VoiceiQ's own ⌘V doesn't count.
    private static func typingPaused() async -> Bool {
        let deadline = Date().addingTimeInterval(typingWait)
        while CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < typingPause {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    static let typingPause: TimeInterval = 0.4
    static let typingWait: TimeInterval = 2

    /// The text this dictation left in the field: the written text after a
    /// swap, else the draft.
    public var text: String? { landed }

    public func stopShowing() {
        stopped = true
    }

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
        // Another app or field in front: no marks over it.
        guard Self.focusedTarget(context: context).map({ CFEqual($0, element) }) == true else {
            return marks.underline([])
        }
        _ = field.sync()
        drawUnderline()
    }

    private func drawUnderline() {
        guard let span = field?.ledger.draft(id) else { return marks.underline([]) }
        guard let clip = Self.visibleFrame(of: element) else { return marks.underline([]) }
        marks.underline(Self.lineRects(in: element, location: span.location, length: span.length)
            .compactMap { Self.clipped($0, to: clip) })
    }

    /// Sets the selection and reads it back. With `holding`, the field must
    /// also still read exactly that text: a key typed between the read and
    /// the selection would shift what the range covers.
    /// Chromium applies the selection in its renderer and answers from its
    /// tree afterwards, so the read-back is polled for up to 200 ms.
    private func select(_ location: Int, _ length: Int, holding value: String? = nil) async -> Bool {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success
        else { return false }
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(40)) }
            guard let now = PasteCheck.reading(of: element) else { return false }
            if let value, now.value != value { return false }
            if now.caret == location, now.selectionLength == length { return true }
        }
        return false
    }

    /// The focused element when it belongs to the frontmost target app and
    /// is the field the dictation started in.
    static func focusedTarget(context: DictationContext) -> AXUIElement? {
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

    private static func slice(_ value: String, _ location: Int, _ length: Int) -> String {
        let units = Array(value.utf16)
        guard location >= 0, length > 0, location + length <= units.count else { return "" }
        // Never half an emoji at the end.
        let end = UTF16.isLeadSurrogate(units[location + length - 1]) ? location + length - 1 : location + length
        return String(decoding: units[location..<end], as: UTF16.self)
    }

    /// The app's field refused a swap for a reason that isn't the user's:
    /// it gets no more drafts until VoiceiQ restarts, so the cost is one
    /// dictation kept as heard.
    private func refusedByApp() {
        if let app = Self.appKey(context) { Self.noDraftApps.insert(app) }
    }

    /// The app a field that never shows a draft belongs to, by bundle ID
    /// so it holds across that app's restarts.
    private static func appKey(_ context: DictationContext) -> String? {
        context.targetAppBundleID ?? context.targetPID.map { "pid \($0)" }
    }

    static func isChromiumOrElectron(bundleID: String?, bundleURL: URL?) -> Bool {
        bundleID.map(AppQuirks.needsManualAccessibility.contains) == true
            || AccessibilityWaker.isElectron(bundleURL)
            || bundleURL.map { !TypingInserter.chromiumMajorVersions(in: $0).isEmpty } == true
    }

    /// The cursor's rect, from the character before it when that is on
    /// the same line: an empty range at the end of an NSTextView reports
    /// the line below.
    static func caretRect(in element: AXUIElement, at caret: Int, of value: String) -> CGRect? {
        let utf16 = value.utf16
        // The whole character before the caret: an emoji is two UTF-16 units.
        if caret > 0, caret <= utf16.count,
           let end = utf16.index(utf16.startIndex, offsetBy: caret).samePosition(in: value),
           let previous = value[..<end].last, !previous.isNewline,
           let rect = bounds(in: element, location: caret - previous.utf16.count, length: previous.utf16.count),
           rect.height > 1 {
            return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        if let rect = bounds(in: element, location: caret, length: 0), rect.height > 1 {
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        return nil
    }

    /// The part of the screen where the field shows text, in AppKit
    /// coordinates: its own frame, cut to every scroll area, web area and
    /// window it sits in. Text scrolled out of a single-line field or out of
    /// a scroll view lies outside it.
    static func visibleFrame(of element: AXUIElement) -> CGRect? {
        guard var visible = frame(of: element) else { return nil }
        var current = element
        for _ in 0..<40 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parent as AnyObject, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(current, 0.25)
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success,
                  let role = role as? String else { continue }
            if ["AXScrollArea", "AXWebArea", "AXWindow"].contains(role), let outer = frame(of: current) {
                visible = visible.intersection(outer)
            }
            if role == "AXWindow" { break }
        }
        return visible.isNull || visible.width < 1 || visible.height < 1 ? nil : visible
    }

    /// An element's AXPosition and AXSize, flipped to AppKit coordinates.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
    }

    /// The visible part of one underlined line: nil when its line is
    /// outside the field, or only a sliver of it shows.
    static func clipped(_ line: CGRect, to visible: CGRect) -> CGRect? {
        guard line.midY >= visible.minY, line.midY <= visible.maxY else { return nil }
        let minX = max(line.minX, visible.minX), maxX = min(line.maxX, visible.maxX)
        guard maxX - minX >= 4 else { return nil }
        return CGRect(x: minX, y: line.minY, width: maxX - minX, height: line.height)
    }

    /// Where the spinner goes for a caret: on its line, kept inside the
    /// field; nil when the caret's line is not in view.
    static func spinnerSpot(for caret: CGRect, in visible: CGRect) -> CGRect? {
        guard caret.midY >= visible.minY, caret.midY <= visible.maxY else { return nil }
        // The spinner is drawn from 3 pt right of this x (`DraftOverlay`).
        let room = DraftOverlaySize.spinner + 5
        let x = min(max(caret.minX, visible.minX), visible.maxX - room)
        guard x >= visible.minX else { return nil }
        return CGRect(x: x, y: caret.minY, width: 0, height: caret.height)
    }

    /// WebKit and Chromium page fields report a selected-text write as
    /// done and ignore it, so they are written by ⌘V.
    static func isInWebArea(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<80 {
            AXUIElementSetMessagingTimeout(current, 0.25)
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == "AXWebArea" { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent as AnyObject, to: AXUIElement.self)
        }
        return false
    }

    /// One rect per line the range covers, from the field's line ranges;
    /// a single rect when the field has no line attributes and the range
    /// fits on one line; none otherwise.
    static func lineRects(in element: AXUIElement, location: Int, length: Int) -> [CGRect] {
        guard length > 0, let oneLine = bounds(in: element, location: location, length: 1) else { return [] }
        let field = frame(of: element)
        let end = location + length
        if let first = line(in: element, at: location), let last = line(in: element, at: end - 1), last >= first {
            var rects: [CGRect] = []
            for number in first...min(last, first + maxLines - 1) {
                guard let lineRange = range(in: element, line: number) else { continue }
                let start = max(location, lineRange.location), stop = min(end, lineRange.location + lineRange.length)
                guard stop > start, let rect = bounds(in: element, location: start, length: stop - start) else { continue }
                rects.append(rect)
            }
            if !rects.isEmpty { return onText(rects, character: oneLine, field: field) }
        }
        guard let whole = bounds(in: element, location: location, length: length) else { return [] }
        return onText([whole], character: oneLine, field: field)
    }

    /// The rects when every one of them lies on a line of text, else none:
    /// an underline is never drawn off the text. Chromium and Electron
    /// fields (VS Code's search box) can answer a range with the whole
    /// field's frame, whose bottom is the field's border, and the draft
    /// then keeps only its spinner and the swap. `character` is the draft's
    /// first character, the measure of one line.
    static let tallestLine: CGFloat = 48

    static func onText(_ rects: [CGRect], character: CGRect, field: CGRect?) -> [CGRect] {
        func isField(_ rect: CGRect) -> Bool {
            guard let field else { return false }
            return abs(rect.minX - field.minX) <= 2 && abs(rect.minY - field.minY) <= 2
                && abs(rect.width - field.width) <= 2 && abs(rect.height - field.height) <= 2
        }
        // No dictated line of text is taller than `tallestLine`: a taller
        // character is a box around more than one line.
        guard character.width >= 1, character.height <= tallestLine, !isField(character) else { return [] }
        // A line with no width (only a space where it wraps) has nothing to mark.
        let lines = rects.filter { $0.width >= 1 }
        // One line taller than a line, or the field itself, and the field's
        // other answers can't be trusted either.
        guard lines.allSatisfy({ $0.height <= character.height * 1.6 && !isField($0) }) else { return [] }
        return lines
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
        guard waiters.isEmpty else { return waiters.removeFirst().resume() }
        locked = false
        // A dictation that ended while another held the field.
        if ledger.drafts.isEmpty { Self.fields.removeAll { $0 === self } }
    }

    /// A dictation is done with its draft; a field with none left is closed.
    func forget(_ id: UUID) {
        ledger.remove(id)
        if ledger.drafts.isEmpty, !locked { Self.fields.removeAll { $0 === self } }
    }
}
#endif
