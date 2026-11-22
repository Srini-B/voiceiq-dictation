import Foundation

public extension Notification.Name {
    /// A ⌘V was posted but the field it aimed at never changed; `object` is
    /// the text, now on the clipboard.
    static let voiceIQPasteMissed = Notification.Name("io.blue.voiceiq.paste-missed")
}

/// Whether a posted ⌘V actually put the text in the field. A synthetic paste
/// has no delivery receipt, so the field is read before the paste and again
/// at about 0.15, 0.5 and 1.5 s. Only a field that is still readable and
/// exactly unchanged at the last read counts as missed; anything else is
/// landed or unknown, and unknown says nothing. FluidVoice checks its pastes
/// the same way (altic-dev/FluidVoice); this is our own implementation.
public enum PasteCheck {
    public struct Reading: Equatable, Sendable {
        public var value: String
        public var caret: Int
        public var selectionLength: Int

        public init(value: String, caret: Int, selectionLength: Int) {
            self.value = value
            self.caret = caret
            self.selectionLength = selectionLength
        }
    }

    public enum Verdict: Equatable, Sendable { case landed, missed, unknown }

    /// Delays after the paste for each read.
    static let readDelays: [TimeInterval] = [0.15, 0.5, 1.5]
    /// Above this the field is not read at all: comparing it costs too much.
    static let maxValueLength = 60_000

    /// `after` is nil when the field can't be read or focus moved to another one.
    public static func verdict(before: Reading, after: Reading?, text: String) -> Verdict {
        guard let after else { return .unknown }
        let added = text.utf16.count
        let grewBy = after.value.utf16.count - before.value.utf16.count
        if after.value != before.value, grewBy == added - before.selectionLength { return .landed }
        if after.caret == before.caret + added, added > 0 { return .landed }
        if occurrences(of: text, in: after.value) > occurrences(of: text, in: before.value) { return .landed }
        return after == before ? .missed : .unknown
    }

    private static func occurrences(of text: String, in value: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return value.components(separatedBy: text).count - 1
    }
}

#if os(macOS)
import AppKit
import ApplicationServices

extension PasteCheck {
    /// The focused element and what it holds, or nil when it can't be read.
    @MainActor
    static func focusedReading() -> (element: AXUIElement, reading: Reading)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let reading = reading(of: element) else { return nil }
        return (element, reading)
    }

    static func reading(of element: AXUIElement) -> Reading? {
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let count = countRef as? Int, count > maxValueLength { return nil }
        var rangeRef: CFTypeRef?
        guard let value = AXInserter.fieldText(of: element), value.utf16.count <= maxValueLength,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return Reading(value: value, caret: range.location, selectionLength: range.length)
    }

    /// Reads the field back after the paste and calls `missed` only on a
    /// certain miss. A key press or click after the paste (Return to send,
    /// say) makes the result unknown, so nothing is said.
    @MainActor
    static func watch(element: AXUIElement, before: Reading, text: String, postedAt: Date, missed: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            var verdict = Verdict.unknown
            for delay in readDelays {
                let wait = postedAt.addingTimeInterval(delay).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !userActed(since: postedAt) else { return }
                let current = focusedReading()
                let sameField = current.map { CFEqual($0.element, element) } ?? false
                verdict = PasteCheck.verdict(before: before, after: sameField ? current?.reading : nil, text: text)
                guard verdict == .missed else { return }
            }
            Log.insertion.warning("⌘V posted but the field never changed — text copied instead")
            missed()
        }
    }

    private static func userActed(since date: Date) -> Bool {
        let elapsed = Date().timeIntervalSince(date)
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
        return types.contains { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < elapsed }
    }
}
#endif
