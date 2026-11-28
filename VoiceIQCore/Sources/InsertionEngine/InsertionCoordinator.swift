#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Foundation
import VoiceIQBridge

/// The 3-tier ladder with the two guards that fix Wispr's most-reported bugs:
///
///   guard 1: frontmost app changed since dictation started, or focus moved to
///            another text field of it → NEVER paste blind (text goes to the
///            clipboard; the HUD offers it — F17)
///   guard 2: secure input active → refuse entirely, no clipboard leak (F18)
///
///   tier 1: AX kAXSelectedTextAttribute with read-back verification
///   tier 2: pasteboard + synthesized ⌘V with guarded restore, or typed key
///           events where ⌘V fails (TypingInserter)
///   tier 3: text left on the clipboard, visible hint
public struct InsertionCoordinator: TextInserting {
    private let paster: PasteInserter

    @MainActor
    public init() {
        self.paster = PasteInserter()
    }

    /// The result as it should land next to the text already in the target
    /// field: spaced, capitalized and punctuated for where the cursor is. Unchanged when the field cannot be
    /// read. Run it before `insert`, so whoever tracks the insert sees the
    /// text that landed.
    @MainActor
    public static func fitted(_ text: String, context: DictationContext) -> String {
        guard let surrounding = AXInserter.surroundingText(targetPID: context.targetPID) else { return text }
        return surrounding.fitted(text)
    }

    /// A plain guarded ⌘V, for writing over a selection the caller set
    /// and checked (`FieldDraft`).
    @MainActor
    public func paste(_ text: String) async -> Bool {
        await paster.paste(text)
    }

    /// Presses Delete once, for taking a selected draft out of a field
    /// whose Accessibility writes don't count (`FieldDraft`). False when
    /// keystrokes can't be posted.
    @MainActor
    public func pressDelete() async -> Bool {
        guard KeystrokeAccess.mayPost, let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.magic)
        }
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 10_000_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Waits out the last paste's read-back and clipboard restore (up to
    /// about 1.5 s), so a paste after it posts without waiting.
    @MainActor
    public func finishPendingPaste() async {
        await paster.finishPendingRestore()
    }

    @MainActor
    public func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        await insertReportingTier(text, context: context).outcome
    }

    /// `insert`, saying whether the text went in by Accessibility (tier 1),
    /// which was then verified, or by a paste or typing.
    @MainActor
    public func insertReportingTier(_ text: String, context: DictationContext) async
        -> (outcome: InsertionOutcome, byAccessibility: Bool) {
        // Before the guards, so the frontmost app and the field they check
        // are still the target after waiting out an earlier paste.
        await paster.finishPendingRestore()
        // Guard 2: secure input — the transcript stays in History only.
        if SecureInput.isActive {
            Log.insertion.warning("secure input active at insert time — refusing (text in History only)")
            return (.blockedSecureField, false)
        }

        // Guard 1: is the user still where they started dictating?
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let expectedPID = context.targetPID, let frontmost, frontmost.processIdentifier != expectedPID {
            Log.insertion.info("frontmost changed (\(context.targetAppName ?? "?", privacy: .private) → \(frontmost.localizedName ?? "?", privacy: .private)) — no blind paste")
            paster.copyOnly(text)
            return (.frontmostChanged, false)
        }

        // The field the text is about to go into, taken before any tier
        // waits: Return goes only to this field.
        let returnTarget = ReturnAfterPaste.isWanted(for: context) ? ReturnAfterPaste.focusedElement() : nil

        // Tier 1: AX direct insertion.
        switch await AXInserter.insert(text, targetPID: context.targetPID, bundleID: context.targetAppBundleID,
                                       startField: context.focusedField?.element) {
        case .landed:
            Log.insertion.info("inserted via AX")
            await ReturnAfterPaste.pressIfWanted(context: context, target: returnTarget)
            return (.inserted, true)
        case .focusElsewhere:
            // PROVEN focus theft — a blind ⌘V would paste into the thief.
            // Same treatment as the frontmost-changed guard: chip, never blind.
            paster.copyOnly(text)
            return (.frontmostChanged, false)
        case .notATextField:
            paster.copyOnly(text)
            return (.fellBackToClipboard, false)
        case .notPossible:
            break
        }

        // Guard 1 re-check: the AX attempt takes up to ~350ms — a ⌘Tab in that
        // window would land the ⌘V in the wrong app (production pass 2).
        if let expectedPID = context.targetPID,
           let nowFront = NSWorkspace.shared.frontmostApplication,
           nowFront.processIdentifier != expectedPID {
            Log.insertion.info("frontmost changed during AX attempt — no blind paste")
            paster.copyOnly(text)
            return (.frontmostChanged, false)
        }

        // Tier 2a: apps where ⌘V fails get the text typed instead.
        let bundleURL = context.targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL }
        if let mode = TypingInserter.mode(bundleID: context.targetAppBundleID, bundleURL: bundleURL) {
            switch await TypingInserter.type(text, mode: mode, targetPID: context.targetPID) {
            case .typed:
                Log.insertion.info("typed instead of pasting (\(String(describing: mode), privacy: .public))")
                await ReturnAfterPaste.pressIfWanted(context: context, target: returnTarget)
                return (.inserted, false)
            case .stopped(let rest):
                // The user switched apps part way: the rest must not land
                // there, and the part already typed must not be pasted twice.
                paster.copyOnly(rest)
                return (.frontmostChanged, false)
            case .unsupported:
                // A real ⌘V in the remote session still pastes it.
                paster.copyOnly(text)
                return (.fellBackToClipboard, false)
            }
        }

        // Tier 2: guarded paste. "true" means the ⌘V was POSTED — there is no
        // OS-level delivery receipt for synthetic paste, so a readable field is
        // read back afterwards (PasteCheck) and a certain miss is copied.
        let before = PasteCheck.focusedReading()
        if await paster.paste(text) {
            Log.insertion.info("⌘V posted")
            guard let before else {
                await ReturnAfterPaste.pressIfWanted(context: context, target: returnTarget)
                return (.inserted, false)
            }
            let postedAt = Date()
            let check = Task { @MainActor [paster] () -> PasteCheck.Verdict in
                await PasteCheck.watch(element: before.element, before: before.reading, text: text, postedAt: postedAt) {
                    paster.copyOnly(text)
                    NotificationCenter.default.post(name: .voiceIQPasteMissed, object: text)
                }
            }
            paster.pasteCheck = check
            // A readable field must show the text before Return goes in: a
            // paste the app ignored would otherwise send whatever draft or
            // command was already in the field.
            if ReturnAfterPaste.isWanted(for: context) {
                if await check.value == .landed {
                    await ReturnAfterPaste.pressIfWanted(context: context, target: returnTarget)
                } else {
                    Log.insertion.info("paste not seen in the field — no Return")
                }
            }
            return (.inserted, false)
        }

        // Tier 3: clipboard floor.
        paster.copyOnly(text)
        return (.fellBackToClipboard, false)
    }
}
#endif
