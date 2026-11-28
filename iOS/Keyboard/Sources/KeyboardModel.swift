import SwiftUI
import UIKit
import VoiceIQBridge

/// The keyboard's side of the bridge. It never records or talks to a model:
/// it sends commands to the app and inserts what comes back.
@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var snapshot = SessionSnapshot()
    @Published private(set) var appAlive = false
    /// A message from the app (a problem, in red) or the keyboard's own hint (in
    /// secondary text), shown for a few seconds.
    @Published private var appNotice: Notice?
    /// A finished dictation that may belong in another field. It is not
    /// typed here unasked; Paste last types it.
    @Published private(set) var waitingResult: Delivery?
    @Published private(set) var waitingForApp = false
    @Published private(set) var hasFullAccess = true
    /// Read once per appearance: UIKit answers wrongly before the host connects.
    @Published private(set) var showsGlobeKey = true
    /// The transcript is in the field as a draft and the writing model
    /// rewrites it: the strip shows the writing animation.
    @Published private(set) var holdsDraft = false

    /// When the app has not acknowledged a command by then, it is asleep:
    /// open it. The app answers in well under 100 ms when it is running.
    static let acknowledgementTimeout: TimeInterval = 0.7
    static let waiting = Notice(text: "Dictation ready. Paste last puts it here.", isProblem: false)

    weak var controller: KeyboardViewController?
    /// Makes the keyboard's edits, so the edit panel can undo a dictation.
    weak var editor: EditController?
    /// Called after a dictation delivery is typed so Hex's suggestion strip can offer Undo dictation.
    var onDidInsertDictation: ((String, String, String) -> Void)?
    private let store = SharedStore.shared
    private var observer: UUID?
    private var timer: Timer?
    private var pendingCommandID: UUID?
    private var pendingSince: Date?
    private var shownNoticeID: UUID?
    /// The waiting result this keyboard has logged, so the log has one line
    /// for it, not one per poll.
    private var loggedWaitingID: UUID?
    /// The result this keyboard held back while it was in no field, logged once.
    private var loggedHeldID: UUID?
    /// The draft this keyboard typed, until its written text comes or it
    /// stays as heard.
    private var draft: KeyboardDraft? {
        didSet { if holdsDraft != (draft != nil) { holdsDraft = draft != nil } }
    }
    /// A draft this keyboard could not type, logged once.
    private var skippedDraftID: UUID?
    /// How long a typed draft waits for its written text.
    private static let draftLimit: TimeInterval = 60
    /// The input session this keyboard is in. Nil until the first poll
    /// after it appears, and once it has been in no field for `moveGap`.
    private var session: InputSession?

    private struct InputSession {
        let documentID: UUID
        var host: String?
        /// How often the app could not be named. The resolver logs each
        /// miss, so polling asks it `hostRetryLimit` times and then stops.
        var hostMisses: Int
        /// Focus came here from another field while the keyboard stayed up.
        /// The field a result left is never reached that way, so the
        /// empty-field guess is not made here.
        let movedHere: Bool
    }

    /// Since when this keyboard has been in no field. Focus that moves from
    /// one field to another can read as no field for one poll (measured in
    /// the iOS 27.2 Simulator); a dismissal lasts longer than `moveGap`.
    private var noFieldSince: Date?
    private static let moveGap: TimeInterval = 1
    private var hostRetriedAt = Date.distantPast
    private static let hostRetryLimit = 3
    /// Fields for an address, a code or a number, besides `TypingBridge.noAssistance`.
    private static let notProse: Set<UITextContentType> = [.username, .emailAddress, .URL]
    /// The last poll's reading of the field. A result is typed on what the
    /// field looks like only when two polls agree, so a reading taken while
    /// the host is still connecting cannot place it.
    private var lastReading: FieldIdentity?

    /// The session phase, trusting the snapshot only while the app is alive.
    /// A dictation the app was recording or writing when it stopped answering
    /// stays `.processing`: iOS suspended the app or ended it, and opening
    /// the app finishes or recovers it.
    var phase: SessionSnapshot.Phase {
        if appAlive { return snapshot.phase }
        return needsAppToFinish ? .processing : .off
    }

    var needsAppToFinish: Bool {
        !appAlive && (snapshot.phase == .processing || snapshot.phase == .recording)
    }

    var lastText: String? { snapshot.delivery?.text }

    /// The keyboard's one-line message. A waiting result is not mentioned
    /// while the next dictation is under way.
    var notice: Notice? {
        appNotice ?? (waitingResult == nil || phase.hasDictation ? nil : Self.waiting)
    }

    // MARK: - Lifecycle

    /// The keyboard on screen. iOS can keep an earlier instance alive in the
    /// same process, still polling, with a text connection that no longer
    /// reaches any field; only this one may type.
    private static weak var onScreen: KeyboardModel?
    private let instanceTag = String(UUID().uuidString.prefix(4))

    func appeared() {
        Self.onScreen = self
        session = nil
        noFieldSince = nil
        hasFullAccess = controller?.hasFullAccess ?? false
        if hasFullAccess { store.noteKeyboardSeen() }
        observer = DarwinNotifier.observe(.state) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        if snapshot.phase.hasDictation {
            KeyboardLog.note("[\(instanceTag)] keyboard shown while \(snapshot.phase.rawValue) (session \(Self.tag(documentID)))")
        }
    }

    func refreshHostTraits() {
        let needsGlobe = controller?.needsInputModeSwitchKey ?? true
        if needsGlobe != showsGlobeKey { showsGlobeKey = needsGlobe }
    }

    /// The keyboard is going: a draft still marked becomes plain text, as
    /// heard. Its written text is in Paste last and History.
    func willDisappear() {
        guard let held = draft else { return }
        draft = nil
        if documentID == held.documentID, let proxy = controller?.textDocumentProxy { held.commit(proxy) }
        KeyboardLog.note("[\(instanceTag)] draft stays as heard: the keyboard was dismissed")
    }

    /// The user is about to edit the field with this keyboard. The draft
    /// is made plain text first, so the edit goes in after it instead of
    /// replacing it, and stays as heard: after an edit the text around the
    /// cursor can match the draft's without being it (a deleted draft after
    /// an earlier copy of its words).
    func userWillEdit() {
        guard let held = draft else { return }
        draft = nil
        if documentID == held.documentID, let proxy = controller?.textDocumentProxy { held.commit(proxy) }
        KeyboardLog.note("[\(instanceTag)] draft stays as heard: the user edited the field")
    }

    func disappeared() {
        if Self.onScreen === self { Self.onScreen = nil }
        if let observer { DarwinNotifier.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
    }

    /// Darwin pings are dropped while a process is suspended, so the keyboard
    /// also polls while it is on screen. Reads are local and cheap.
    private func refresh() {
        trackSession()
        if let held = draft, documentID == held.documentID, let proxy = controller?.textDocumentProxy,
           !held.follow(proxy) {
            draft = nil
            held.commit(proxy)
            KeyboardLog.note("[\(instanceTag)] draft stays as heard: the field changed around it")
        }
        let fresh = store.snapshot
        if fresh != snapshot { snapshot = fresh }
        let alive = store.appIsAlive()
        if alive != appAlive { appAlive = alive }
        if let pendingCommandID, store.handledCommandID == pendingCommandID {
            self.pendingCommandID = nil
            waitingForApp = false
        }
        if waitingForApp, let pendingSince, Date().timeIntervalSince(pendingSince) > 12 {
            waitingForApp = false
            pendingCommandID = nil
        }
        deliverIfNeeded()
        dropDraftIfOver()
        typeDraftIfNeeded()
        showNoticeIfNeeded()
    }

    // MARK: - Actions

    func micTapped() {
        guard hasFullAccess else {
            controller?.openURL(BridgeURL.setup)
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch phase {
        case .starting, .recording:
            // The text goes where Stop was tapped.
            let field = fieldForCommand()
            KeyboardLog.note("[\(instanceTag)] stop in \(Self.describe(field))")
            send(KeyboardCommand(action: .stop, field: field))
        case .processing:
            if needsAppToFinish { controller?.openURL(BridgeURL.app) }
        case .warm, .off:
            start()
        }
    }

    func cancelTapped() {
        guard phase == .recording else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        send(KeyboardCommand(action: .cancel))
    }

    struct Notice: Equatable {
        let id = UUID()
        let text: String
        let isProblem: Bool
    }

    /// Types the last result here, wherever it belonged.
    func pasteLast() {
        guard let delivery = snapshot.delivery else {
            // Without Full Access the app's last dictation can't be read, not that there is none.
            return flash(hasFullAccess ? "Nothing dictated yet" : "Allow Full Access to paste dictations", for: 3, isProblem: false)
        }
        guard insert(delivery.text) != nil, delivery.id != store.insertedDeliveryID else { return }
        store.markInserted(delivery)
        waitingResult = nil
        KeyboardLog.note("[\(instanceTag)] result typed with Paste last in \(Self.describe(currentField()))")
    }

    private func flash(_ text: String, for seconds: Double, isProblem: Bool) {
        let shown = Notice(text: text, isProblem: isProblem)
        appNotice = shown
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.appNotice == shown { self?.appNotice = nil }
        }
    }

    private func start() {
        let field = fieldForCommand()
        KeyboardLog.note("[\(instanceTag)] start in \(Self.describe(field))")
        let command = KeyboardCommand(action: .start, field: field)
        let alive = appAlive
        send(command)
        waitingForApp = true
        pendingCommandID = command.id
        pendingSince = Date()
        guard alive else {
            openApp(for: command)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.acknowledgementTimeout) { [weak self] in
            guard let self, self.pendingCommandID == command.id,
                  self.store.handledCommandID != command.id else { return }
            self.openApp(for: command)
        }
    }

    private func send(_ command: KeyboardCommand) {
        store.append(command)
    }

    private func openApp(for command: KeyboardCommand) {
        controller?.openURL(BridgeURL.start(commandID: command.id, host: command.hostBundleID))
    }

    // MARK: - Where the keyboard is

    /// The input session, new each time a field takes focus
    /// (`FieldIdentity.documentID`). Nil once the keyboard is dismissed, while
    /// this model can still be polling with its view in a window.
    private var documentID: UUID? {
        controller.flatMap { TypingLogTraits.documentIdentifier(of: $0.textDocumentProxy) }
    }

    /// Notes each new input session, so a result can tell whether the keyboard
    /// has been in another field of its app since (`Delivery.isFirstReturn`).
    private func trackSession() {
        guard Self.onScreen === self, controller?.viewIfLoaded?.window != nil else {
            session = nil
            return
        }
        guard let documentID else {
            let since = noFieldSince ?? Date()
            noFieldSince = since
            if Date().timeIntervalSince(since) > Self.moveGap { session = nil }
            return
        }
        noFieldSince = nil
        guard session?.documentID != documentID else { return }
        let host = controller.flatMap(HostAppResolver.currentHost(for:))
        session = InputSession(documentID: documentID, host: host, hostMisses: host == nil ? 1 : 0,
                               movedHere: session != nil)
        lastReading = nil
        store.noteFieldVisit(host: session?.host, session: documentID)
    }

    /// The app, the session and the text around the cursor: everything a
    /// keyboard can say about the field it is in. The app is the one named
    /// for this session; a tap can come before a poll has seen the session.
    private func currentField() -> FieldIdentity {
        let proxy = controller?.textDocumentProxy
        let documentID = documentID
        return FieldIdentity(hostBundleID: session?.documentID == documentID ? session?.host : nil,
                             documentID: documentID,
                             draft: Draft.fingerprint(before: proxy?.documentContextBeforeInput,
                                                      after: proxy?.documentContextAfterInput))
    }

    /// The field a tap on Dictate or Stop is for. The tap can come before
    /// the next poll has seen a new session.
    private func fieldForCommand() -> FieldIdentity {
        trackSession()
        resolveHostIfMissing(now: true)
        return currentField()
    }

    /// Whether the field takes ordinary text. A result is typed into an
    /// address, code or number field only when Stop was tapped there.
    private var fieldTakesProse: Bool {
        guard let proxy = controller?.textDocumentProxy else { return false }
        if let type = proxy.textContentType ?? nil,
           TypingBridge.noAssistance.contains(type) || Self.notProse.contains(type) { return false }
        return (proxy.keyboardType ?? .default) == .default
    }

    /// The arbiter often names the app only a moment after the keyboard
    /// appears. Asked again when a decision needs it: once a second and
    /// `hostRetryLimit` times at most while polling, and at once for a tap
    /// (`now`).
    private func resolveHostIfMissing(now: Bool = false) {
        guard let current = session, current.host == nil, current.documentID == documentID else { return }
        guard now || (current.hostMisses < Self.hostRetryLimit && Date().timeIntervalSince(hostRetriedAt) > 1) else { return }
        hostRetriedAt = Date()
        guard let host = controller.flatMap(HostAppResolver.currentHost(for:)) else {
            session?.hostMisses += 1
            return
        }
        session?.host = host
        store.noteFieldVisit(host: host, session: current.documentID)
    }

    private static func describe(_ field: FieldIdentity) -> String {
        "\(field.hostBundleID ?? "an unresolved host"), session \(tag(field.documentID)), \(field.draft == nil ? "empty" : "with text")"
    }

    /// Enough of a session's ID to tell two apart in the log.
    private static func tag(_ documentID: UUID?) -> String {
        documentID.map { String($0.uuidString.prefix(4)) } ?? "unknown"
    }

    // MARK: - Results

    /// Types a finished dictation into its field, once (`Delivery.route`).
    ///
    /// A result belongs in the field where Stop was tapped, or where Dictate
    /// was when it was stopped from outside a keyboard, and waits for a
    /// keyboard there. iOS does not let a keyboard recognise a field it has
    /// left, so on return the field is judged by its app and the text around
    /// the cursor; anywhere that does not fit, the result is only offered.
    /// Only the keyboard on screen may act (iOS can keep an earlier instance
    /// alive, still polling, with a text connection that reaches no field),
    /// and a result is marked handled only by the keyboard that types it.
    private func deliverIfNeeded() {
        guard Self.onScreen === self, controller?.viewIfLoaded?.window != nil else { return }
        guard let delivery = snapshot.delivery, delivery.isPending(handledID: store.insertedDeliveryID) else {
            if waitingResult != nil { waitingResult = nil }
            return
        }
        if let named = delivery.replacesDraft, named == draft?.id || named == store.typedDraftID {
            return finishDraft(with: delivery)
        }
        // A dismissed keyboard can keep polling with its view in a window.
        // It is in no field, so it must not type the result or mark it handled.
        guard documentID != nil else {
            if loggedHeldID != delivery.id {
                loggedHeldID = delivery.id
                KeyboardLog.note("[\(instanceTag)] result held: this keyboard is in no field")
            }
            return
        }
        if delivery.destination?.hostBundleID != nil { resolveHostIfMissing() }
        let here = currentField()
        let settled = here == lastReading
        lastReading = here
        let route = delivery.route(in: here, handledID: store.insertedDeliveryID,
                                   firstReturn: session?.movedHere == false
                                       && delivery.isFirstReturn(to: here, visits: store.fieldVisits),
                                   takesProse: fieldTakesProse)
        switch route {
        case .type(let match):
            guard match == .sameSession || match == .unaddressed || settled else { return }
            if waitingResult != nil { waitingResult = nil }
            store.markInserted(delivery)
            let waited = Int(Date().timeIntervalSince(delivery.createdAt).rounded())
            let replacesSelection = !(controller?.textDocumentProxy.selectedText ?? "").isEmpty
            let inserted = insert(delivery.text)
            // Hex's Undo chip only deletes the dictation; over a selection, the
            // edit panel's Undo is the one that brings the selected text back.
            if let inserted, !replacesSelection {
                onDidInsertDictation?(inserted.fitted, inserted.before, inserted.after)
            }
            KeyboardLog.note(inserted != nil
                ? "[\(instanceTag)] result typed in \(Self.describe(here)): \(match.rawValue), waited \(waited)s"
                : "[\(instanceTag)] result not typed: no text field")
        case .offer:
            guard settled else { return }
            if waitingResult != delivery { waitingResult = delivery }
            guard loggedWaitingID != delivery.id else { return }
            loggedWaitingID = delivery.id
            let destination = delivery.destination.map(Self.describe) ?? "no field"
            KeyboardLog.note("[\(instanceTag)] result waits for \(destination); offered in \(Self.describe(here))")
        case .leave:
            if waitingResult != nil { waitingResult = nil }
        }
    }

    // MARK: - Drafts

    /// Types the transcript as an underlined draft while the writing model
    /// rewrites it (`SessionSnapshot.draft`), only in the input session Stop
    /// was tapped in, and says so (`SharedStore.typedDraftID`). The written
    /// text then replaces it (`finishDraft`). Anywhere else, and over a
    /// selection, the written text comes alone as before.
    private func typeDraftIfNeeded() {
        guard draft == nil, let offered = snapshot.draft, offered.id != store.typedDraftID,
              offered.id != skippedDraftID, offered.isFreshDraft(), appAlive, snapshot.phase == .processing,
              Self.onScreen === self, controller?.viewIfLoaded?.window != nil,
              let proxy = controller?.textDocumentProxy, let documentID,
              offered.route(in: currentField(), handledID: nil, firstReturn: false) == .type(.sameSession)
        else { return }
        guard let typed = KeyboardDraft.type(offered.text, id: offered.id, documentID: documentID, into: proxy,
                                             fit: Self.fitted) else {
            skippedDraftID = offered.id
            KeyboardLog.note("[\(instanceTag)] draft not typed: text is selected, or it could not be swapped later; the written text comes alone")
            return
        }
        draft = typed
        // Undo replays edits before the cursor, which the draft has moved.
        editor?.resetUndo()
        // Only once it is in: the app then sends the written text to replace it.
        store.typedDraftID = offered.id
        KeyboardLog.note("[\(instanceTag)] draft typed in \(Self.describe(currentField()))")
    }

    /// The written text for a draft (`Delivery.replacesDraft`). It replaces
    /// the draft only in the input session this keyboard typed it in, and
    /// only while the draft is still exactly there (`KeyboardDraft.replace`).
    /// Otherwise the draft stays as heard and the written text is in Paste
    /// last and History. It is never typed beside the draft.
    private func finishDraft(with delivery: Delivery) {
        if waitingResult != nil { waitingResult = nil }
        guard let held = draft, held.id == delivery.replacesDraft else {
            store.markInserted(delivery)
            KeyboardLog.note("[\(instanceTag)] written text not typed: its draft went in where this keyboard no longer is, and stays as heard")
            return
        }
        // Focus moving between fields reads as no field for one poll.
        guard let documentID else { return }
        draft = nil
        store.markInserted(delivery)
        guard documentID == held.documentID, let proxy = controller?.textDocumentProxy else {
            KeyboardLog.note("[\(instanceTag)] written text not typed: the keyboard moved to another field; the draft stays as heard")
            return
        }
        Task { @MainActor [weak self] in
            let swap = await held.replace(with: delivery.text, in: proxy, fit: Self.fitted)
            guard let self else { return }
            switch swap {
            case .retyped(let fitted):
                // The cursor is right after the written text: Undo takes it
                // out, as for a dictation typed in.
                self.editor?.recordDictation(inserted: fitted)
                self.onDidInsertDictation?(fitted, held.before, held.after)
                KeyboardLog.note("[\(self.instanceTag)] written text replaced its draft in \(Self.describe(self.currentField()))")
            case .kept:
                KeyboardLog.note("[\(self.instanceTag)] written text not typed: the draft was edited or moved, so it stays as heard")
            }
        }
    }

    /// A draft whose written text will not come here stays as heard: the
    /// keyboard moved to another field (whose host has committed it already),
    /// the dictation ended without it, or the app stopped answering.
    private func dropDraftIfOver() {
        guard let held = draft else { return }
        let moved = documentID.map { $0 != held.documentID } ?? false
        let expired = Date().timeIntervalSince(held.typedAt) > Self.draftLimit
        // Published and waiting for this keyboard to be in a field again.
        let writtenWaits = snapshot.delivery.map {
            $0.replacesDraft == held.id && $0.isPending(handledID: store.insertedDeliveryID)
        } ?? false
        guard moved || expired || (!writtenWaits && (!appAlive || snapshot.phase != .processing)) else { return }
        draft = nil
        if !moved, documentID != nil, let proxy = controller?.textDocumentProxy { held.commit(proxy) }
        KeyboardLog.note("[\(instanceTag)] draft stays as heard: \(moved ? "the keyboard moved to another field" : "no written text came")")
    }

    /// The fitting `insert` does, for a draft and its written text alike.
    nonisolated private static func fitted(_ text: String, before: String, after: String) -> String {
        SurroundingText(before: before, after: after).fitted(text)
    }

    private func showNoticeIfNeeded() {
        guard let fresh = snapshot.notice, fresh.id != shownNoticeID,
              Date().timeIntervalSince(fresh.createdAt) < 10 else { return }
        shownNoticeID = fresh.id
        flash(fresh.text, for: 4, isProblem: true)
    }

    /// Fits the new text to the text around the cursor: spaces on both
    /// sides and a capital at the start of a sentence.
    @discardableResult
    private func insert(_ text: String) -> (fitted: String, before: String, after: String)? {
        guard let proxy = controller?.textDocumentProxy, !text.isEmpty else { return nil }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        let surrounding = SurroundingText(before: before, after: after)
        let fitted = surrounding.fitted(text)
        editor?.type(fitted)
        return (fitted, before, after)
    }
}

/// Keyboard events for the app's Session log.
enum KeyboardLog {
    static func note(_ line: String) {
        SharedStore.shared.appendKeyboardLog(line)
    }
}
