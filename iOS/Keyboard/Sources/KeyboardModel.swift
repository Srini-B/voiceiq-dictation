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
    private let store = SharedStore.shared
    private var observer: UUID?
    private var timer: Timer?
    private var pendingCommandID: UUID?
    private var pendingSince: Date?
    private var shownNoticeID: UUID?
    private let local = KeyboardDictation.shared
    private var localObserver: AnyCancellable?

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
        // The bar follows a dictation the keyboard runs by itself too.
        localObserver = local.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let view = controller?.view, controller?.hasFullAccess == true { local.keyboardAppeared(in: view) }
        local.onDeliver = { text, mode in Self.deliverLocal(text, mode: mode) }
        local.onNotice = { text in Self.onScreen?.show(notice: text) }
        hasFullAccess = controller?.hasFullAccess ?? false
        if hasFullAccess { store.noteKeyboardSeen() }
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
            local.keyboardHidden()
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
        let fresh = store.snapshot
        if fresh != snapshot { snapshot = fresh }
        // With the snapshot, so a new recording never shows the last one's words.
        let newText = local.phase != .off ? local.liveText : phase == .recording ? store.liveText : ""
        if newText != liveText { liveText = newText }
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
        case .recording:
            if local.phase == .recording { local.stop() } else { send(KeyboardCommand(action: .stop, mode: mode)) }
        case .processing:
            if needsAppToFinish { controller?.openURL(BridgeURL.app) }
        case .warm, .off:
            start()
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
        if let answer { store.insertedDeliveryID = answer.id }
        answer = nil
    }

    private func start() {
        let host = controller.flatMap(HostAppResolver.currentHost(for:))
        let context = mode == .ask ? controller?.textDocumentProxy.selectedText : nil
        // A running app session keeps recording in the app, as before.
        if !appAlive {
            if let blocker = local.blocker() {
                KeyboardLog.note("[\(instanceTag)] in-keyboard dictation unavailable: \(blocker)")
            } else {
                let mode = self.mode
                local.onStartFailed = { [weak self] in self?.startThroughApp(mode: mode, context: context, host: host) }
                if local.start(mode: mode, selectedText: context, host: host) { return }
            }
        }
        startThroughApp(mode: mode, context: context, host: host)
    }

    private func startThroughApp(mode: KeyboardMode, context: String?, host: String?) {
        KeyboardLog.note("[\(instanceTag)] start in \(host ?? "an unresolved host")")
        let command = KeyboardCommand(action: .start, mode: mode, context: context, hostBundleID: host)
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

    /// A result of an in-keyboard dictation. The keyboard on screen types it
    /// (an Ask answer opens the answer panel); with none on screen it goes on
    /// the clipboard after the same two seconds the app waits.
    private static func deliverLocal(_ text: String, mode: KeyboardMode) {
        if mode != .ask { SharedStore.shared.keyboardDelivery = Delivery(mode: mode, text: text, hostBundleID: nil) }
        if let model = onScreen, model.controller?.viewIfLoaded?.window != nil {
            if mode == .ask {
                model.answer = Delivery(mode: .ask, text: text, hostBundleID: nil)
            } else {
                let typed = model.insert(text)
                KeyboardLog.note(typed ? "[\(model.instanceTag)] result typed" : "[\(model.instanceTag)] result not typed: no text field")
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if mode == .ask, let model = onScreen {
                model.answer = Delivery(mode: .ask, text: text, hostBundleID: nil)
            } else if let model = onScreen, model.insert(text) {
                KeyboardLog.note("[\(model.instanceTag)] result typed")
            } else {
                UIPasteboard.general.string = text
                KeyboardLog.note("result not typed by a keyboard; copied to the clipboard (keyboard)")
            }
        }
    }

    private func show(notice text: String) {
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
