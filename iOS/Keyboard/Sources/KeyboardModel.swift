import Combine
import SwiftUI
import UIKit
import VoiceIQBridge

/// The keyboard's side of the bridge. While the app runs a session it sends
/// commands to the app and inserts what comes back. Without one, the keyboard
/// dictates by itself with the app's own pipeline (`KeyboardDictation`), so
/// the app never opens; when it cannot, the tap goes through the app.
@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var snapshot = SessionSnapshot()
    @Published private(set) var appAlive = false
    /// The words heard so far in the dictation being recorded.
    @Published private(set) var liveText = ""
    @Published private(set) var answer: Delivery?
    @Published private(set) var notice: String?
    @Published private(set) var waitingForApp = false
    @Published private(set) var hasFullAccess = true
    /// Read once per appearance: UIKit answers wrongly before the host connects.
    @Published private(set) var showsGlobeKey = true
    @Published var mode: KeyboardMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// When the app has not acknowledged a command by then, it is asleep:
    /// open it. The app answers in well under 100 ms when it is running.
    static let acknowledgementTimeout: TimeInterval = 0.7
    /// A dictation finished longer ago than this is not typed into whatever
    /// field happens to be open now; it stays available behind Paste last.
    static let autoInsertWindow: TimeInterval = 120
    private static let modeKey = "keyboardMode"

    weak var controller: KeyboardViewController?
    /// Called after the keyboard itself writes to the clipboard.
    var onOwnCopy: (() -> Void)?
    /// Called after the keyboard edits the field, so typing rereads the text.
    var onEdited: (() -> Void)?
    /// A held result to offer in the suggestion strip, or nil.
    var onOffer: ((String?) -> Void)?
    private let store = SharedStore.shared
    private var observer: UUID?
    private var timer: Timer?
    private var pendingCommandID: UUID?
    private var pendingSince: Date?
    /// The start command of the dictation this keyboard began, for the hold
    /// that started it, however long: kept until it is released, another
    /// start, or the app reports that dictation over.
    var holdStart: KeyboardCommand?
    private var shownNoticeID: UUID?
    private let local = KeyboardDictation.shared
    private var localObserver: AnyCancellable?
    var offeredHeldID: UUID?

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(KeyboardMode.init(rawValue:)) ?? .dictate
    }

    /// The session phase, trusting the snapshot only while the app is alive.
    /// A dictation the app was still writing when it stopped answering stays
    /// `.processing`: iOS suspended the app or ended it, and opening the app
    /// finishes or recovers it.
    var phase: SessionSnapshot.Phase {
        if local.phase != .off { return local.phase }
        if appAlive { return snapshot.phase }
        return needsAppToFinish ? .processing : .off
    }

    var needsAppToFinish: Bool { !appAlive && local.phase == .off && snapshot.phase == .processing }

    var recordingStartedAt: Date? { local.recordingStartedAt ?? snapshot.recordingStartedAt }

    /// The newest result, from the app or from a dictation run in the keyboard.
    var lastText: String? {
        [snapshot.delivery, store.keyboardDelivery].compactMap { $0 }.max { $0.createdAt < $1.createdAt }?.text
    }

    // MARK: - Lifecycle

    /// The keyboard on screen. iOS can keep an earlier instance alive in the
    /// same process, still polling, with a text connection that no longer
    /// reaches any field; only this one may type.
    private static weak var onScreen: KeyboardModel?
    private let instanceTag = String(UUID().uuidString.prefix(4))

    func appeared() {
        Self.onScreen = self
        hasFullAccess = controller?.hasFullAccess ?? false
        if hasFullAccess { store.noteKeyboardSeen() }
        // The bar follows a dictation the keyboard runs by itself too.
        localObserver = local.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if hasFullAccess, let view = controller?.view { local.keyboardAppeared(in: view) }
        local.onDeliver = { text, mode in Self.onScreen?.deliverLocal(text, mode: mode) ?? false }
        local.onNotice = { text in Self.onScreen?.show(notice: text) }
        observer = DarwinNotifier.observe(.state) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refreshHostTraits() {
        let needsGlobe = controller?.needsInputModeSwitchKey ?? true
        if needsGlobe != showsGlobeKey { showsGlobeKey = needsGlobe }
    }

    func disappeared() {
        if Self.onScreen === self {
            Self.onScreen = nil
            local.keyboardHidden(textBefore: controller?.textDocumentProxy.documentContextBeforeInput)
        }
        if let observer { DarwinNotifier.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
    }

    /// Darwin pings are dropped while a process is suspended, so the keyboard
    /// also polls while it is on screen. Reads are local and cheap.
    private func refresh() {
        if hasFullAccess, Self.onScreen === self, Date().timeIntervalSince(store.keyboardSeenAt ?? .distantPast) >= 1 {
            store.keyboardSeenAt = Date()
        }
        if Self.onScreen === self {
            local.healIfStalled()
            local.publishState(store: store)
        }
        let fresh = store.snapshot
        if fresh != snapshot {
            if !waitingForApp, snapshot.phase == .recording || snapshot.phase == .processing,
               fresh.phase == .warm || fresh.phase == .off {
                holdStart = nil
            }
            snapshot = fresh
        }
        // With the snapshot, so a new recording never shows the last one's words.
        let newText = local.phase != .off ? local.liveText : phase == .recording ? store.liveText : ""
        if newText != liveText { liveText = newText }
        let alive = store.appIsAlive()
        if alive != appAlive { appAlive = alive }
        if let pendingCommandID, acknowledged(pendingCommandID) {
            self.pendingCommandID = nil
            waitingForApp = false
        }
        if waitingForApp, let pendingSince, Date().timeIntervalSince(pendingSince) > 12 {
            waitingForApp = false
            pendingCommandID = nil
            holdStart = nil
        }
        deliverIfNeeded()
        deliverHeldIfNeeded()
        showNoticeIfNeeded()
    }

    // MARK: - Actions

    func micTapped() {
        guard hasFullAccess else {
            controller?.openURL(BridgeURL.setup)
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        holdStart = nil
        switch phase {
        case .recording:
            stopRecording()
        case .processing:
            if needsAppToFinish { controller?.openURL(BridgeURL.app) }
        case .warm, .off:
            start()
        }
    }

    /// Touch-down on the Hex key: without an app session, the keyboard's own
    /// capture starts now, unseen (`KeyboardDictation.arm`), so the first
    /// words are not lost while the touch becomes a tap or a hold.
    func dictationKeyPressed() {
        guard hasFullAccess, phase == .off || phase == .warm, !appAlive, local.blocker() == nil else { return }
        let mode = self.mode
        let context = mode == .ask ? controller?.textDocumentProxy.selectedText : nil
        let host = controller.flatMap(HostAppResolver.currentHost(for:))
        // This touch's own fallback: a WebKit microphone that does not start
        // sends this dictation through the app.
        local.onStartFailed = { [weak self] in self?.startThroughApp(mode: mode, context: context, host: host) }
        local.arm(mode: mode, selectedText: context, host: host,
                  document: controller?.textDocumentProxy.fieldID,
                  textBefore: controller?.textDocumentProxy.documentContextBeforeInput)
    }

    /// The touch on the Hex key became a slide or was cancelled.
    func dictationKeyAbandoned() {
        local.discard(reason: "slide or cancelled touch")
    }

    private func stopRecording() {
        if local.phase == .recording { local.stop() } else { send(KeyboardCommand(action: .stop, mode: mode)) }
    }

    /// Lifting the dictation key after a hold finishes the dictation the hold
    /// started. One the app hasn't reported as recording yet (it is starting,
    /// warming, or the keyboard is switching to the app and back) gets a stop
    /// bound to its start command: the app applies it once that dictation
    /// records, and never to another one, even once it records.
    func holdReleased() {
        if let holdStart {
            self.holdStart = nil
            if phase == .recording { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            send(KeyboardCommand(action: .stop, mode: mode, startID: holdStart.id))
        } else if phase == .recording {
            micTapped()
        }
    }

    func cancelTapped() {
        guard phase == .recording else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if local.phase == .recording { local.cancel() } else { send(KeyboardCommand(action: .cancel, mode: mode)) }
    }

    func pasteLast() {
        guard let lastText else { return }
        insert(lastText)
    }

    func insertAnswer() {
        guard let answer else { return }
        insert(answer.text)
        dismissAnswer()
    }

    func copyAnswer() {
        guard let answer else { return }
        UIPasteboard.general.string = answer.text
        onOwnCopy?()
        dismissAnswer()
    }

    func dismissAnswer() {
        // Only the app's delivery is acknowledged: a local or held answer
        // must not overwrite the acknowledgement of one still in its window.
        if let answer, answer.id == snapshot.delivery?.id { store.insertedDeliveryID = answer.id }
        answer = nil
    }

    private func start() {
        // The Hex key's touch-down already started recording.
        if local.isArmed {
            local.keep()
            return
        }
        let host = controller.flatMap(HostAppResolver.currentHost(for:))
        let context = mode == .ask ? controller?.textDocumentProxy.selectedText : nil
        // A running app session keeps recording in the app, as before.
        if !appAlive {
            if let blocker = local.blocker() {
                KeyboardLog.note("[\(instanceTag)] in-keyboard dictation unavailable: \(blocker)")
            } else {
                let mode = self.mode
                local.onStartFailed = { [weak self] in self?.startThroughApp(mode: mode, context: context, host: host) }
                if local.start(mode: mode, selectedText: context, host: host,
                               document: controller?.textDocumentProxy.fieldID,
                  textBefore: controller?.textDocumentProxy.documentContextBeforeInput) { return }
            }
        }
        startThroughApp(mode: mode, context: context, host: host)
    }

    private func startThroughApp(mode: KeyboardMode, context: String?, host: String?) {
        KeyboardLog.note("[\(instanceTag)] start in \(host ?? "an unresolved host")")
        let command = KeyboardCommand(action: .start, mode: mode, context: context, hostBundleID: host)
        let alive = appAlive
        send(command)
        holdStart = command
        waitingForApp = true
        pendingCommandID = command.id
        pendingSince = Date()
        guard alive else {
            openApp(for: command)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.acknowledgementTimeout) { [weak self] in
            guard let self, self.pendingCommandID == command.id, !self.acknowledged(command.id) else { return }
            self.openApp(for: command)
        }
    }

    /// The app took this start: it handled it, or a later stop bound to it
    /// (the app handles commands in order, and leaves a stop with its start).
    private func acknowledged(_ start: UUID) -> Bool {
        guard let handled = store.handledCommandID else { return false }
        return handled == start || store.commands.first { $0.id == handled }?.startID == start
    }

    private func send(_ command: KeyboardCommand) {
        store.append(command)
    }

    private func openApp(for command: KeyboardCommand) {
        controller?.openURL(BridgeURL.start(commandID: command.id, host: command.hostBundleID))
    }

    // MARK: - Results

    /// Types a finished dictation into this field, once.
    ///
    /// Whichever app the keyboard is in when the result arrives gets it, even
    /// if the dictation started in another app: the user stopped it here.
    /// Only the keyboard on screen may type (iOS can keep an earlier instance
    /// alive, still polling, with a text connection that reaches no field),
    /// and a result is marked delivered only by the keyboard that types it.
    /// When no keyboard types it, the app puts it on the clipboard.
    private func deliverIfNeeded() {
        guard let delivery = snapshot.delivery, delivery.id != store.insertedDeliveryID else { return }
        guard Date().timeIntervalSince(delivery.createdAt) < Self.autoInsertWindow else { return }
        guard Self.onScreen === self, controller?.viewIfLoaded?.window != nil else { return }
        if delivery.mode == .ask {
            if answer?.id != delivery.id { answer = delivery }
            return
        }
        store.insertedDeliveryID = delivery.id
        let typed = insert(delivery.text)
        KeyboardLog.note(typed ? "[\(instanceTag)] result typed" : "[\(instanceTag)] result not typed: no text field")
    }

    /// A result of an in-keyboard dictation, for the keyboard on screen: an
    /// Ask answer opens the answer panel; anything else is typed.
    private func deliverLocal(_ text: String, mode: KeyboardMode) -> Bool {
        guard controller?.viewIfLoaded?.window != nil else { return false }
        if mode == .ask {
            answer = Delivery(mode: .ask, text: text, hostBundleID: nil)
            return true
        }
        let typed = insert(text)
        KeyboardLog.note(typed ? "[\(instanceTag)] result typed" : "[\(instanceTag)] result not typed: no text field")
        return typed
    }

    /// A result held while no keyboard was on screen (anomalyco/hex #2163):
    /// typed into the same field within 30 s, otherwise offered in the
    /// suggestion strip for 10 minutes.
    private func deliverHeldIfNeeded() {
        guard Self.onScreen === self, controller?.viewIfLoaded?.window != nil else { return }
        guard let held = store.heldDictation else { return offer(nil) }
        let proxy = controller?.textDocumentProxy
        switch held.delivery(in: proxy?.fieldID, host: controller.flatMap(HostAppResolver.currentHost(for:)),
                             textBefore: proxy?.documentContextBeforeInput) {
        case .insert:
            take(held)
        case .offer:
            offer(held)
        case .expired:
            offer(nil)
        }
    }

    private func offer(_ held: HeldDictation?) {
        guard held?.id != offeredHeldID else { return }
        offeredHeldID = held?.id
        onOffer?(held?.text)
    }

    /// The strip's offer was tapped.
    func pasteHeld() {
        let current = store.heldDictation
        // Otherwise the offer is refreshed and nothing is typed, not even a
        // newer result that would go into this field by itself.
        guard let held = Self.heldToPaste(offered: offeredHeldID, current: current) else {
            return offer(current.flatMap { $0.delivery(in: nil) == .expired ? nil : $0 })
        }
        take(held)
    }

    /// Delivers a held result once: an Ask answer opens the answer panel,
    /// anything else is typed.
    private func take(_ held: HeldDictation) {
        store.markHeldHandled(held)
        offer(nil)
        if held.mode == .ask {
            answer = Delivery(mode: .ask, text: held.text, hostBundleID: nil)
        } else {
            insert(held.text)
            KeyboardLog.note("[\(instanceTag)] held result typed")
        }
    }

    /// The result a tap on the offer pastes: the one the strip shows, while
    /// it is still the held result and not expired.
    static func heldToPaste(offered: UUID?, current: HeldDictation?, now: Date = Date()) -> HeldDictation? {
        guard let current, current.id == offered, current.delivery(in: nil, at: now) != .expired else { return nil }
        return current
    }

    func show(notice text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    private func showNoticeIfNeeded() {
        guard let fresh = snapshot.notice, fresh.id != shownNoticeID,
              Date().timeIntervalSince(fresh.createdAt) < 10 else { return }
        shownNoticeID = fresh.id
        notice = fresh.text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == fresh.text { self?.notice = nil }
        }
    }

    /// Fits the new text to the text around the cursor: spaces on both
    /// sides and a capital at the start of a sentence.
    @discardableResult
    private func insert(_ text: String) -> Bool {
        guard let proxy = controller?.textDocumentProxy, !text.isEmpty else { return false }
        let surrounding = SurroundingText(before: proxy.documentContextBeforeInput ?? "",
                                          after: proxy.documentContextAfterInput ?? "")
        proxy.insertText(surrounding.fitted(text))
        onEdited?()
        return true
    }

    // MARK: - Keys

    func deleteBackward() {
        controller?.textDocumentProxy.deleteBackward()
        onEdited?()
    }

    func insertSpace() {
        controller?.textDocumentProxy.insertText(" ")
        onEdited?()
    }

    func insertReturn() {
        controller?.textDocumentProxy.insertText("\n")
        onEdited?()
    }
}

/// Keyboard events for the app's Session log.
enum KeyboardLog {
    static func note(_ line: String) {
        SharedStore.shared.appendKeyboardLog(line)
    }
}

private extension UITextDocumentProxy {
    /// `documentIdentifier`, read without bridging: iOS declares it
    /// non-optional but returns nil while focus moves between fields, and
    /// reading that as a Swift `UUID` traps.
    var fieldID: UUID? {
        (self as AnyObject).perform(#selector(getter: UITextDocumentProxy.documentIdentifier))?.takeUnretainedValue() as? UUID
    }
}
