import SwiftUI
import UIKit
import VoiceIQBridge

/// The keyboard's side of the bridge. It never records or talks to a model:
/// it sends commands to the app and inserts what comes back.
@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var snapshot = SessionSnapshot()
    @Published private(set) var appAlive = false
    /// The words heard so far in the dictation being recorded.
    @Published private(set) var liveText = ""
    @Published private(set) var notice: String?
    @Published private(set) var waitingForApp = false
    @Published private(set) var hasFullAccess = true
    /// Read once per appearance: UIKit answers wrongly before the host connects.
    @Published private(set) var showsGlobeKey = true

    /// When the app has not acknowledged a command by then, it is asleep:
    /// open it. The app answers in well under 100 ms when it is running.
    static let acknowledgementTimeout: TimeInterval = 0.7
    /// A dictation finished longer ago than this is not typed into whatever
    /// field happens to be open now; it stays available behind Paste last.
    static let autoInsertWindow: TimeInterval = 120

    weak var controller: KeyboardViewController?
    /// Makes the keyboard's edits, so the edit panel can undo a dictation.
    weak var editor: EditController?
    private let store = SharedStore.shared
    private var observer: UUID?
    private var timer: Timer?
    private var pendingCommandID: UUID?
    private var pendingSince: Date?
    private var shownNoticeID: UUID?

    /// The session phase, trusting the snapshot only while the app is alive.
    /// A dictation the app was still writing when it stopped answering stays
    /// `.processing`: iOS suspended the app or ended it, and opening the app
    /// finishes or recovers it.
    var phase: SessionSnapshot.Phase {
        if appAlive { return snapshot.phase }
        return needsAppToFinish ? .processing : .off
    }

    var needsAppToFinish: Bool { !appAlive && snapshot.phase == .processing }

    var lastText: String? { snapshot.delivery?.text }

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
        if Self.onScreen === self { Self.onScreen = nil }
        if let observer { DarwinNotifier.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
    }

    /// Darwin pings are dropped while a process is suspended, so the keyboard
    /// also polls while it is on screen. Reads are local and cheap.
    private func refresh() {
        let fresh = store.snapshot
        if fresh != snapshot { snapshot = fresh }
        // With the snapshot, so a new recording never shows the last one's words.
        let newText = phase == .recording ? store.liveText : ""
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
            send(KeyboardCommand(action: .stop))
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

    func pasteLast() {
        guard let lastText else { return }
        insert(lastText)
    }

    private func start() {
        let host = controller.flatMap(HostAppResolver.currentHost(for:))
        KeyboardLog.note("[\(instanceTag)] start in \(host ?? "an unresolved host")")
        let command = KeyboardCommand(action: .start, hostBundleID: host)
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
        store.insertedDeliveryID = delivery.id
        let typed = insert(delivery.text)
        KeyboardLog.note(typed ? "[\(instanceTag)] result typed" : "[\(instanceTag)] result not typed: no text field")
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
        editor?.type(surrounding.fitted(text))
        return true
    }
}

/// Keyboard events for the app's Session log.
enum KeyboardLog {
    static func note(_ line: String) {
        SharedStore.shared.appendKeyboardLog(line)
    }
}
