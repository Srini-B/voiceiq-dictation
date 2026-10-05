import SwiftUI
import UIKit
import VoiceIQBridge

/// The keyboard's side of the bridge. It never records or talks to a model:
/// it sends commands to the app and inserts what comes back.
@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var snapshot = SessionSnapshot()
    @Published private(set) var appAlive = false
    @Published private(set) var level: Float = 0
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
    private let store = SharedStore.shared
    private var observer: UUID?
    private var timer: Timer?
    private var pendingCommandID: UUID?
    private var pendingSince: Date?
    private var shownNoticeID: UUID?

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(KeyboardMode.init(rawValue:)) ?? .dictate
    }

    /// The session phase, trusting the snapshot only while the app is alive.
    var phase: SessionSnapshot.Phase { appAlive ? snapshot.phase : .off }

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
            Task { @MainActor in self?.tick() }
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
    private func tick() {
        refresh()
        let newLevel = phase == .recording ? store.level : 0
        if newLevel != level { level = newLevel }
    }

    private func refresh() {
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
            send(KeyboardCommand(action: .stop, mode: mode))
        case .processing:
            break
        case .warm, .off:
            start()
        }
    }

    func cancelTapped() {
        guard phase == .recording else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        send(KeyboardCommand(action: .cancel, mode: mode))
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
        KeyboardLog.note("[\(instanceTag)] start in \(host ?? "an unresolved host")")
        let context = mode == .ask ? controller?.textDocumentProxy.selectedText : nil
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
        return true
    }

    // MARK: - Keys

    func deleteBackward() {
        controller?.textDocumentProxy.deleteBackward()
    }

    func insertSpace() {
        controller?.textDocumentProxy.insertText(" ")
    }

    func insertReturn() {
        controller?.textDocumentProxy.insertText("\n")
    }
}

/// Keyboard events for the app's Session log.
enum KeyboardLog {
    static func note(_ line: String) {
        SharedStore.shared.appendKeyboardLog(line)
    }
}
