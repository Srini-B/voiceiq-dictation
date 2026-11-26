#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// Owns the system-wide CGEventTap that powers the bare-modifier dictation key.
///
/// Design (docs/design/architecture.md — HotkeyEngine):
///  - Dedicated thread with its own CFRunLoop; the callback only classifies events,
///    runs the pure `HotkeyProcessor` under a lock (microseconds), and forwards
///    intents to the owner via a closure.
///  - Consumes the configured key's flagsChanged events (that's what makes fn *ours*)
///    and ⌘Esc key-downs, but ONLY while a session is active. Everything else passes.
///  - Self-healing: re-enables on kCGEventTapDisabledBy* and polls tapIsEnabled
///    every 5s — a non-nil tap is not a healthy tap.
///  - Sendable by hand, like `GlobalShortcutEngine`: the tap thread, the health
///    timer and the owner share it. The grammar is guarded by `lock`, the tap's
///    lifecycle (state, thread, port, run loop, timer) by `lifecycleLock`;
///    neither is held while a callback runs or while `start()` waits.
public final class EventTapEngine: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        /// Tap creation failed — Accessibility permission is missing.
        case permissionDenied
        case running
    }

    public var state: State { withLifecycle { $0.state } }

    /// Called with each intent, on an arbitrary internal thread — the owner hops
    /// to the main actor.
    public var onIntent: ((HotkeyIntent) -> Void)?
    /// Called when the tap had to be revived (telemetry for the #1 field failure).
    public var onTapRevived: (() -> Void)?
    /// Called on the tap thread for each Return or Enter key-down, before the
    /// frontmost app receives it: the event waits until this returns, so keep
    /// it well under the tap's timeout.
    public var onReturnKeyDown: (() -> Void)?

    private var trigger: DictationTrigger
    private let lock = NSLock()
    private var processor = HotkeyProcessor()
    private var keyIsDown = false
    /// Key code of a combo whose keyDown we consumed, so its keyUp is
    /// swallowed too instead of reaching the frontmost app as a stray release.
    private var comboKeyHeld: UInt16?
    private var middleMouse = MiddleMouseHold()
    /// Set by the app while a session is in flight beyond the grammar's view
    /// (transcribing/inserting, or UI-started hands-free) so ⌘Esc still cancels
    /// (audit L8/L13 — the machine supported cancel, the tap never delivered it).
    private var externalSessionActive = false

    private struct Lifecycle {
        var state: State = .stopped
        var thread: Thread?
        var port: CFMachPort?
        var runLoop: CFRunLoop?
        var healthTimer: DispatchSourceTimer?
    }

    private let lifecycleLock = NSLock()
    private var lifecycle = Lifecycle()
    private let timerQueue = DispatchQueue(label: "io.blue.voiceiq.hotkey.timer")

    private func withLifecycle<T>(_ body: (inout Lifecycle) -> T) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body(&lifecycle)
    }

    public init(trigger: DictationTrigger = .default) {
        self.trigger = trigger
    }

    deinit {
        stop()
    }

    public func setTrigger(_ newTrigger: DictationTrigger) {
        lock.lock()
        // Same key ⇒ keep keyIsDown: resetting the edge detector while the user
        // is physically holding the key would swallow the coming key-up and
        // strand the session (reachable via any settings write re-applying
        // hotkey config mid-hold).
        if trigger != newTrigger {
            trigger = newTrigger
            keyIsDown = false
            comboKeyHeld = nil
        }
        lock.unlock()
    }

    /// The coordinator refused our .begin — the grammar's session is phantom.
    public func resetGrammar() {
        lock.lock()
        processor.reset()
        lock.unlock()
    }

    public func setExternalSessionActive(_ active: Bool) {
        lock.lock()
        externalSessionActive = active
        lock.unlock()
    }

    /// Starts the tap. Returns false (state == .permissionDenied) without Accessibility trust.
    /// Safe to call again after the user grants Accessibility (onboarding flow).
    @discardableResult
    public func start() -> Bool {
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.threadMain(started: started)
        }
        thread.name = "io.blue.voiceiq.eventtap"
        thread.qualityOfService = .userInteractive
        let alreadyRunning: Bool? = withLifecycle { life in
            if life.state == .permissionDenied {
                life.thread = nil
                life.state = .stopped
            }
            guard life.thread == nil else { return life.state == .running }
            life.thread = thread
            return nil
        }
        if let alreadyRunning {
            if alreadyRunning { startHealthTimer() }
            return alreadyRunning
        }
        thread.start()

        // The thread reports tap creation success or failure.
        _ = started.wait(timeout: .now() + 2)
        let running = withLifecycle { $0.state == .running }
        if running { startHealthTimer() }
        return running
    }

    public func stop() {
        let life = withLifecycle { life in
            defer { life = Lifecycle() }
            return life
        }
        life.healthTimer?.cancel()
        if let runLoop = life.runLoop { CFRunLoopStop(runLoop) }
        if let port = life.port { CGEvent.tapEnable(tap: port, enable: false) }
    }

    // MARK: - Tap thread

    private func threadMain(started: DispatchSemaphore) {
        defer { started.signal() }
        // The other-mouse events are for the middle-mouse trigger, which
        // watches them and never consumes them.
        let types: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<EventTapEngine>.fromOpaque(userInfo).takeUnretainedValue()
                return engine.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Log.hotkey.error("EventTapEngine: tap creation failed — Accessibility not granted")
            // Only while this thread is still the engine's: a later start owns it otherwise.
            withLifecycle { if $0.thread === Thread.current { $0.state = .permissionDenied } }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        // A stop() that ran while the tap was being created ended this start.
        let current = withLifecycle { life -> Bool in
            guard life.thread === Thread.current else { return false }
            life.port = tap
            life.runLoop = CFRunLoopGetCurrent()
            life.state = .running
            // Enabled under the lock, so a stop() cannot disable it first.
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        guard current else {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            return
        }
        Log.hotkey.info("EventTapEngine: tap running (trigger=\(self.trigger.displayName, privacy: .public))")
        started.signal()
        // In slices, not CFRunLoopRun(): a stop() before the loop first runs
        // has nothing to stop, and this thread would run on alone.
        while withLifecycle({ $0.thread === Thread.current }) {
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        CFMachPortInvalidate(tap)
        Log.hotkey.info("EventTapEngine: run loop exited")
    }

    // MARK: - Event classification (tap thread)

    /// ⌘Esc, with no other modifier: the cancel shortcut.
    public static func isCancel(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 53 && flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == .maskCommand
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Tap health: the OS silently disables taps that are slow or during login events.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if reviveTap(onlyIfDisabled: false) {
                Log.hotkey.warning("EventTapEngine: tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public) — re-enabled")
                onTapRevived?()
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .flagsChanged:
            lock.lock()
            // While Settings records a shortcut the press belongs to that row,
            // not to dictation. A key already held keeps its release so the
            // edge detector is not stranded.
            guard case .modifier(let configured) = trigger,
                  keyCode == configured.keyCode, !(ShortcutCapture.isActive && !keyIsDown) else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            let isDown = configured.isDown(in: event.flags)
            guard isDown != keyIsDown else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            keyIsDown = isDown
            let fx = processor.handle(isDown ? .hotkeyDown : .hotkeyUp, at: now)
            lock.unlock()
            apply(fx)
            return nil // consume: this key is ours

        case .keyDown:
            // Our own synthetic events (the InsertionEngine's ⌘V) are tagged with a
            // magic userData value and must never feed the grammar.
            guard event.getIntegerValueField(.eventSourceUserData) != SyntheticEventTag.magic else {
                return Unmanaged.passUnretained(event)
            }
            // Autorepeats are echoes, not intent: a key held down before the
            // session started must not abort it, and repeated Space/Esc must not
            // re-fire gestures (audit #14).
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return Unmanaged.passUnretained(event)
            }
            if keyCode == 36 || keyCode == 76 { // Return, keypad Enter
                onReturnKeyDown?()
            }
            #if os(macOS)
            if keyCode == 53 { ReturnAfterPaste.noteEscape() }
            #endif
            // A shortcut being recorded is the row's to consume, Esc included.
            guard !ShortcutCapture.isActive else { return Unmanaged.passUnretained(event) }
            lock.lock()
            // A combo trigger is a tap: down and up reach the grammar together.
            if case .combo(let shortcut) = trigger,
               shortcut.matches(eventFlags: event.flags, keyCode: UInt16(keyCode)) {
                comboKeyHeld = UInt16(keyCode)
                var fx = processor.handle(.hotkeyDown, at: now)
                fx.intents += processor.handle(.hotkeyUp, at: now).intents
                lock.unlock()
                apply(fx)
                return nil
            }
            // ⌘Esc cancels grammar sessions AND externally-tracked ones
            // (in-flight transcription, UI-started hands-free). A bare Esc
            // passes through: it belongs to the app being dictated into.
            let cancel = Self.isCancel(keyCode: keyCode, flags: event.flags)
            if cancel, externalSessionActive, !processor.isSessionActive {
                lock.unlock()
                onIntent?(.cancel)
                return nil
            }
            guard processor.isSessionActive else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            if cancel {
                let fx = processor.handle(.escDown, at: now)
                lock.unlock()
                apply(fx)
                return nil // consume ⌘Esc only while dictating
            }
            // The accidental-chord abort exists for bare modifiers, where a
            // letter while the modifier is still held means the user meant
            // ⌥-something. A combo already carries its key, and a key pressed
            // after the modifier was released (⌘-Tab to another app right
            // after the tap) is not a chord: it passes and the session stays.
            guard trigger.isModifier, keyIsDown else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            let fx = processor.handle(.otherKeyDown, at: now)
            lock.unlock()
            apply(fx)
            return Unmanaged.passUnretained(event) // typing passes through

        case .keyUp:
            lock.lock()
            guard let held = comboKeyHeld, held == UInt16(keyCode) else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            comboKeyHeld = nil
            lock.unlock()
            return nil

        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            trackMiddleMouse(type: type, event: event)
            return Unmanaged.passUnretained(event) // every middle press is still the app's

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func trackMiddleMouse(type: CGEventType, event: CGEvent) {
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return }
        lock.lock()
        defer { lock.unlock() }
        // While Settings records a trigger the click is the recorder's.
        guard trigger == .middleMouse, !ShortcutCapture.isActive else {
            middleMouse.up()
            return
        }
        switch type {
        case .otherMouseDown:
            let id = middleMouse.down(at: event.location)
            timerQueue.asyncAfter(deadline: .now() + MiddleMouseHold.holdDuration) { [weak self] in
                self?.middleMouseHeld(id)
            }
        case .otherMouseDragged:
            middleMouse.dragged(to: event.location)
        default:
            middleMouse.up()
        }
    }

    /// The press is a tap of the trigger, like a combo's: it starts a
    /// hands-free dictation or stops the one recording.
    private func middleMouseHeld(_ id: Int) {
        // A release the tap missed (it was disabled for a moment) must not
        // read as a hold.
        let stillDown = CGEventSource.buttonState(.combinedSessionState, button: .center)
        lock.lock()
        guard trigger == .middleMouse, middleMouse.fire(id), stillDown else {
            lock.unlock()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var fx = processor.handle(.hotkeyDown, at: now)
        fx.intents += processor.handle(.hotkeyUp, at: now).intents
        lock.unlock()
        apply(fx)
    }

    private func apply(_ fx: HotkeyProcessor.Effects) {
        for intent in fx.intents {
            onIntent?(intent)
        }
    }

    // MARK: - Health polling

    private func startHealthTimer() {
        // Made only once it will be kept: a suspended source released
        // without resume() crashes.
        withLifecycle { life in
            guard life.state == .running, life.healthTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self, self.reviveTap(onlyIfDisabled: true) else { return }
                Log.hotkey.warning("EventTapEngine: health poll found tap disabled — re-enabled")
                self.onTapRevived?()
            }
            life.healthTimer = timer
            timer.resume()
        }
    }

    /// Re-enables the tap, under the lifecycle lock so a concurrent `stop()`
    /// never has its disabled tap turned back on. True when it re-enabled it.
    private func reviveTap(onlyIfDisabled: Bool) -> Bool {
        withLifecycle { life in
            guard let port = life.port else { return false }
            if onlyIfDisabled, CGEvent.tapIsEnabled(tap: port) { return false }
            CGEvent.tapEnable(tap: port, enable: true)
            return true
        }
    }
}
#endif
