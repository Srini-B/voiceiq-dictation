import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import VoiceIQCore

/// First-launch onboarding: welcome → key → permissions → Globe key → how to →
/// try it → done. Warm, plain-spoken, one screen at a time (experience spec §5).
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var onClosed: (() -> Void)?

    convenience init(
        onFinished: @escaping () -> Void,
        onClosed: @escaping () -> Void,
        latestRecord: @escaping () -> DictationRecord? = { nil }
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        // Pin the SwiftUI content to the design size — assigning an NSHostingView
        // whose fitting size is unbounded (Spacer + maxHeight: .infinity) resizes
        // the window to near screen height.
        window.contentView = NSHostingView(
            rootView: OnboardingFlow(onFinished: onFinished, latestRecord: latestRecord)
                .frame(width: 640, height: 560)
        )
        window.setContentSize(NSSize(width: 640, height: 560))
        window.center()
        // Setup sends people into System Settings for each permission, and
        // every trip steals focus. VoiceiQ is an accessory app,
        // so it has no Dock icon and no Cmd-Tab entry — once this window fell
        // behind System Settings there was NO way back to it except finding the
        // menu bar icon, and users reported exactly that. Floating keeps it in
        // sight the whole time, which also means they watch the checkmark flip.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.init(window: window)
        self.onClosed = onClosed
        window.delegate = self
    }

    /// Red-button close mid-flow must stop any live resources — the mic-test
    /// engine kept the mic (and the orange dot) alive forever (audit #6).
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .onboardingWindowClosed, object: nil)
        onClosed?()
    }
}

extension Notification.Name {
    static let onboardingWindowClosed = Notification.Name("io.blue.voiceiq.onboarding.closed")
    static let onboardingJumpToScreen = Notification.Name("io.blue.voiceiq.onboarding.jump")
}

private struct OnboardingFlow: View {
    let onFinished: () -> Void
    var latestRecord: () -> DictationRecord? = { nil }

    /// The raw value is the index in voiceiq://onboarding/<n>: 0 welcome,
    /// 1 key, 2 permissions, 3 Globe key, 4 how to, 5 try it, 6 done.
    enum Screen: Int, CaseIterable {
        case welcome, apiKey, permissions, globeKey, howTo, tryIt, done
    }

    @State private var screen: Screen = .welcome
    /// Where we came from, so Back honours screens that were skipped (the Globe
    /// step) instead of guessing with rawValue - 1. Reported from the wild:
    /// "I accidentally skipped past the key screen and I can't get back."
    @State private var backStack: [Screen] = []
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: VoiceIQUI.Spacing.l)
            currentScreen
                .frame(maxWidth: 480)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(screen)
            Spacer()
            progressDots
                .padding(.bottom, VoiceIQUI.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VQ.Colors.canvas)
        .overlay(alignment: .topLeading) {
            if !backStack.isEmpty {
                Button(action: goBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(VoiceIQUI.TypeScale.body())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                        .padding(.horizontal, VoiceIQUI.Spacing.s)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .padding(.leading, VoiceIQUI.Spacing.s)
                .padding(.top, VoiceIQUI.Spacing.s)
                .transition(.opacity)
            }
        }
        .animation(VoiceIQMotion.expressiveDefaultSpatial, value: screen)
        // voiceiq://onboarding/<n> — deep-link to a screen (automation + UI checks).
        .onReceive(NotificationCenter.default.publisher(for: .onboardingJumpToScreen)) { note in
            if let index = note.object as? Int, let target = Screen(rawValue: index) {
                backStack.append(screen)
                screen = target
            }
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch screen {
        case .welcome: WelcomeScreen(onNext: { advance() })
        case .apiKey: APIKeyScreen(onNext: { advance() })
        case .permissions: PermissionsScreen(onNext: { advance() })
        case .globeKey: GlobeKeyScreen(onNext: { advance() })
        case .howTo: HowToScreen(onNext: { advance() })
        case .tryIt: TryItScreen(onNext: { advance() }, latestRecord: latestRecord)
        case .done: DoneScreen(onFinish: onFinished)
        }
    }

    private func advance() {
        var next = Screen(rawValue: screen.rawValue + 1) ?? .done
        // Skip the Globe screen when the dictation key is not Globe, or when the
        // system action is already Do Nothing.
        if next == .globeKey,
           SettingsStore().dictationTrigger != .modifier(.fn) || !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey {
            next = .howTo
        }
        backStack.append(screen)
        screen = next
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        screen = previous
    }

    private var progressDots: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            ForEach(Screen.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == screen ? VoiceIQUI.Colors.primary : VoiceIQUI.Colors.outlineVariant)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Shared pieces

private struct ScreenScaffold<Content: View>: View {
    let headline: String
    let body_: String
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(_ headline: String, _ body: String, @ViewBuilder content: () -> Content) {
        self.headline = headline
        self.body_ = body
        self.content = content()
    }

    var body: some View {
        VStack(spacing: VoiceIQUI.Spacing.l) {
            Text(headline)
                .font(VoiceIQUI.TypeScale.display(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(VoiceIQUI.Colors.onSurface)
                .multilineTextAlignment(.center)
            Text(body_)
                .font(VoiceIQUI.TypeScale.body(grad: scheme == .dark ? 25 : 0))
                .foregroundStyle(VQ.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(VoiceIQUI.TypeScale.title())
                // Disabled needs its OWN pair. Keeping onPrimary (a dark navy in
                // dark mode) over a grey container put dark text on a dark pill:
                // 1.37:1, effectively invisible — reported from the wild.
                // Material's 38% disabled label would only reach 2.8:1, and this
                // particular button is what a first-time user stares at while
                // they go and fetch their API key, so it is legible on purpose:
                // 4.2:1 dark / 3.4:1 light, still obviously inactive.
                .foregroundStyle(disabled ? VoiceIQUI.Colors.onSurface.opacity(0.55) : VoiceIQUI.Colors.onPrimary)
                .padding(.horizontal, VoiceIQUI.Spacing.xl)
                .padding(.vertical, VoiceIQUI.Spacing.s)
                .background(Capsule().fill(disabled
                    ? VoiceIQUI.Colors.onSurface.opacity(0.14)
                    : VoiceIQUI.Colors.primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Screens

private struct WelcomeScreen: View {
    let onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demoLevel = LevelSource()
    @State private var heardShown = ""
    @State private var cleanShown = ""
    @State private var demoTask: Task<Void, Never>?

    // The whole promise in one loop: messy thought in, clean sentence out.
    private static let heardLine = "um so let's meet at 1pm… actually no, 2pm"
    private static let cleanLine = "Let's meet at 2pm."

    var body: some View {
        ScreenScaffold("Speak. It types.", "Press a key, say the thing, and polished text lands wherever your cursor is.") {
            VStack(spacing: VoiceIQUI.Spacing.m) {
                WaveformView(level: demoLevel, processing: false)
                    .frame(width: 200, height: 48)
                    .background(Capsule().fill(VoiceIQUI.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                demoText
                    .frame(width: 420, height: 48)
                PrimaryButton(title: "Get started", action: onNext)
            }
        }
        .onAppear(perform: startDemo)
        .onDisappear {
            demoTask?.cancel() // process-lifetime leak otherwise (audit L32)
            demoTask = nil
        }
    }

    @ViewBuilder
    private var demoText: some View {
        if reduceMotion {
            VStack(spacing: 2) {
                Text("“\(Self.heardLine)”")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .italic()
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                Text(Self.cleanLine)
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(VoiceIQUI.Colors.onSurface)
            }
        } else {
            VStack(spacing: 2) {
                Text(heardShown.isEmpty ? " " : "“\(heardShown)”")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .italic()
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant.opacity(cleanShown.isEmpty ? 1 : 0.45))
                Text(cleanShown.isEmpty ? " " : cleanShown)
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(VoiceIQUI.Colors.onSurface)
            }
            // The typewriter IS the animation — inherited implicit animations
            // crossfade every character and ghost the previous loop's text.
            .transaction { $0.animation = nil }
        }
    }

    private func startDemo() {
        guard !reduceMotion, demoTask == nil else { return }
        demoTask = Task { @MainActor in
            while !Task.isCancelled {
                heardShown = ""; cleanShown = ""
                // "Hearing": the messy line types in while the waveform speaks.
                for char in Self.heardLine {
                    guard !Task.isCancelled else { return }
                    heardShown.append(char)
                    demoLevel.value = Float.random(in: 0.35...0.8)
                    try? await Task.sleep(nanoseconds: 38_000_000)
                }
                demoLevel.value = 0.08
                try? await Task.sleep(nanoseconds: 450_000_000)
                // "Writing": the clean line lands, correction already applied.
                for char in Self.cleanLine {
                    guard !Task.isCancelled else { return }
                    cleanShown.append(char)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_400_000_000)
            }
        }
    }
}

private struct APIKeyScreen: View {
    let onNext: () -> Void
    @State private var key = ""
    @State private var validating = false
    @State private var failed = false
    @State private var saveFailed = false
    /// Set when the server actively rejected the key, so we can say so instead of
    /// the generic "didn't work".
    @State private var rejection: String?
    /// The check could not be performed. We let them past, but we say so.
    @State private var unverified = false
    /// Replacing a key that is already stored — bug report: a user who saved a
    /// bad key had to UNINSTALL the app to get another chance at this screen.
    @State private var replacing = false
    /// A saved key completes this step.
    @State private var storedKeyExists = KeychainStore.hasModelKey
    private var showingField: Bool { !storedKeyExists || replacing }

    var body: some View {
        ScreenScaffold("Bring your own key.", "VoiceiQ uses your AssemblyAI API key. It's stored in your Mac's Keychain and only ever sent to AssemblyAI.") {
            VStack(spacing: VoiceIQUI.Spacing.s) {
                if !showingField {
                    Label("Key already in your Keychain", systemImage: "checkmark.circle.fill")
                        .font(VoiceIQUI.TypeScale.body())
                        .foregroundStyle(VoiceIQUI.Colors.success)
                    // Without this the only way out of a stored-but-wrong key was
                    // to uninstall the app (dogfood).
                    Button("Use a different key") {
                        replacing = true
                        key = ""
                        rejection = nil
                        unverified = false
                    }
                    .buttonStyle(.plain)
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                } else {
                    SecureField("Paste your key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(VoiceIQUI.TypeScale.code)
                        .frame(width: 320)
                    if failed {
                        Text(rejection.map { "That key was rejected: \($0)" }
                             ?? "That key didn't work — check it in your AssemblyAI dashboard.")
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VoiceIQUI.Colors.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }
                    if unverified {
                        Text("Couldn't reach AssemblyAI to check this key — saved it anyway. Your first dictation will tell you for sure.")
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }
                    if saveFailed {
                        Text("Couldn't save to your Mac's Keychain — try again.")
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VoiceIQUI.Colors.error)
                    }
                    Link("Sign up at AssemblyAI ($50 free credit)", destination: URL(string: "https://www.assemblyai.com/dashboard/signup")!)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                    Link("Copy your key from the AssemblyAI dashboard", destination: URL(string: "https://www.assemblyai.com/dashboard/api-keys")!)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                }
                if validating {
                    ProgressView().controlSize(.small)
                } else {
                    PrimaryButton(title: showingField ? "Save & continue" : "Continue",
                                  disabled: showingField && key.trimmingCharacters(in: .whitespaces).isEmpty) {
                        showingField ? validate() : onNext()
                    }
                    if showingField {
                        // Don't wall off mic/accessibility setup behind the key —
                        // the menu bar nudges toward Settings → Advanced until one exists.
                        Button("I'll add it later", action: onNext)
                            .buttonStyle(.plain)
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                    }
                }
            }
        }
    }

    private func validate() {
        // Guard the re-entry: `validating` swaps the button for a spinner, but a
        // fast double-click can land two taps before SwiftUI redraws, and a user
        // staring at a rejection WILL mash it.
        guard !validating else { return }
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        failed = false
        rejection = nil
        unverified = false
        Task {
            let check = await AssemblyAIClient(apiKey: { candidate }).validateKey()

            if case .rejected(let detail) = check {
                // The server answered and said no. This is the case that used to
                // slip through: validateKey returned a bare false, and a
                // false-negative from a 1s reachability probe sent it down the
                // "offline, save anyway" path — which then stored the bad key and
                // advanced, with no way back to this screen.
                rejection = detail
                failed = true
                validating = false
                return
            }

            unverified = (check == .unreachable)

            guard KeychainStore.saveAPIKey(candidate) else {
                saveFailed = true
                validating = false
                return
            }
            storedKeyExists = true
            replacing = false
            validating = false
            // An unreachable check still advances — a captive portal must not
            // wall someone out of setup — but the notice above says so plainly
            // rather than implying the key was verified.
            if unverified {
                // Let them read it before the screen changes.
                try? await Task.sleep(nanoseconds: 1_600_000_000)
            }
            onNext()
        }
    }
}

/// Every permission dictation uses, on one checklist. Each row asks, opens the
/// right System Settings pane with a floating guide beside it, and flips to
/// Allowed by itself: read twice a second while the screen is up and again
/// whenever VoiceiQ comes back to the front.
///
/// Input Monitoring is deliberately not on the list. The dictation key and the
/// shortcuts are read through active event taps (`CGEvent.tapCreate` with
/// `.defaultTap`), which macOS gates on Accessibility; nothing in VoiceiQ uses
/// a listen-only tap or IOHID, the APIs that need Input Monitoring.
private struct PermissionsScreen: View {
    let onNext: () -> Void
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibility = KeystrokeAccess.isReady
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    /// Asked for and not granted yet: the row shows a spinner.
    @State private var waiting: Set<SetupPermission> = []
    @State private var pollTimer: Timer?
    @State private var slowGrantTimer: Timer?
    @State private var slowGrant = false

    /// On 27.3+ with Accessibility on, the posting grant only reads true
    /// after a restart, so waiting would only hide the way forward. State,
    /// refreshed by the poll: SwiftUI does not observe `AXIsProcessTrusted()`.
    @State private var needsRestart = Self.restartNeeded

    private static var restartNeeded: Bool {
        !KeystrokeAccess.isReady && AXIsProcessTrusted() && KeystrokeAccess.isSplit
    }

    var body: some View {
        ScreenScaffold("Give VoiceiQ access.", "Each switch lives in System Settings. Rows turn green by themselves as you allow them.") {
            VStack(spacing: VoiceIQUI.Spacing.m) {
                VStack(spacing: 0) {
                    PermissionRow(icon: "mic", title: "Microphone",
                                  benefit: "Hears you while you dictate",
                                  state: state(of: .microphone)) { allow(.microphone) }
                    if microphone {
                        // The old microphone screen's check: is sound actually
                        // arriving from the selected input?
                        MicCheck()
                            .padding(.leading, PermissionRow.textInset)
                            .padding(.trailing, VQ.Spacing.m)
                            .padding(.bottom, VQ.Spacing.s)
                    }
                    hairline
                    PermissionRow(icon: "keyboard", title: KeystrokeAccess.listName,
                                  benefit: "Watches for your key and types where your cursor is",
                                  state: state(of: .accessibility)) { allow(.accessibility) }
                    hairline
                    PermissionRow(icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                                  benefit: "Optional. Reads names on screen for spelling",
                                  state: state(of: .screenRecording), optional: true) { allow(.screenRecording) }
                }
                .background(RoundedRectangle(cornerRadius: VQ.Radius.card).fill(VQ.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: VQ.Radius.card).strokeBorder(VQ.Colors.hairline, lineWidth: 1))
                .animation(VoiceIQMotion.expressiveFastSpatial, value: waiting)
                .animation(VoiceIQMotion.expressiveFastSpatial, value: [microphone, accessibility, screenRecording])

                if needsRestart || (slowGrant && (waiting.contains(.accessibility) || waiting.contains(.screenRecording))) {
                    HStack(spacing: VoiceIQUI.Spacing.xs) {
                        Text(needsRestart
                             ? "Allowed it? macOS applies it after a restart."
                             : "Allowed it and it doesn't turn green? Quit and reopen VoiceiQ.")
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VQ.Colors.muted)
                        Button("Restart VoiceiQ") { AppRestart.now() }
                            .controlSize(.small)
                    }
                }

                HStack(spacing: VoiceIQUI.Spacing.s) {
                    Text("The first two are required")
                        .font(GTFont.flex(VQ.TypeScale.meta.size, weight: VQ.TypeScale.meta.weight))
                        .foregroundStyle(VQ.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: VoiceIQUI.Spacing.s)
                    // The microphone was always skippable (the menu bar keeps
                    // saying what is missing); typing at the cursor was not.
                    if accessibility && !microphone {
                        Button("Set up later", action: onNext)
                            .buttonStyle(.plain)
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VQ.Colors.muted)
                    }
                    PrimaryButton(title: "Continue", disabled: !(microphone && accessibility), action: onNext)
                }
            }
        }
        .onAppear {
            stopTimers()
            refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear { stopAll() }
        // Closing the window bypasses onDisappear (audit #6).
        .onReceive(NotificationCenter.default.publisher(for: .onboardingWindowClosed)) { _ in stopAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var hairline: some View {
        Rectangle().fill(VQ.Colors.hairline).frame(height: 1)
    }

    private func isGranted(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        }
    }

    private func state(of permission: SetupPermission) -> PermissionRow.Status {
        if isGranted(permission) { return .allowed }
        return waiting.contains(permission) ? .waiting : .needed
    }

    private func allow(_ permission: SetupPermission) {
        switch permission {
        case .microphone:
            // macOS asks ONCE per install. After a denial the prompt never
            // reappears, so the second click goes to System Settings instead.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                waiting.insert(.microphone)
                Task {
                    let ok = await AVCaptureDevice.requestAccess(for: .audio)
                    microphone = ok
                    waiting.remove(.microphone)
                }
                return
            }
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            PermissionGuidePanel.shared.show(.microphone)
        case .accessibility:
            // kAXTrustedCheckOptionPrompt's value; the C global is mutable, so Swift 6 refuses it.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            KeystrokeAccess.requestPostAccess()
            NSWorkspace.shared.open(KeystrokeAccess.settingsURL)
            PermissionGuidePanel.shared.show(.accessibility)
            startSlowGrantTimer()
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                PermissionGuidePanel.shared.show(.screenRecording)
            }
            startSlowGrantTimer()
        }
        waiting.insert(permission)
        refresh()
    }

    private func refresh() {
        let trusted = KeystrokeAccess.isReady
        if trusted, !accessibility {
            // Wake the engine NOW — otherwise the Try-It screen two steps
            // later is dead until relaunch (production pass 2).
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "accessibility")
        }
        accessibility = trusted
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenRecording = CGPreflightScreenCaptureAccess()
        needsRestart = Self.restartNeeded

        let landed = waiting.filter { isGranted($0) }
        if !landed.isEmpty {
            waiting.subtract(landed)
            // They are standing in System Settings right now. Bring the flow
            // back so the next row is in front of them.
            NSApp.activate(ignoringOtherApps: true)
        }
        if let shown = PermissionGuidePanel.shared.permission, isGranted(shown) {
            PermissionGuidePanel.shared.close()
        }
    }

    private func startSlowGrantTimer() {
        slowGrantTimer?.invalidate()
        slowGrant = false
        slowGrantTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            Task { @MainActor in slowGrant = true }
        }
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        slowGrantTimer?.invalidate(); slowGrantTimer = nil
    }

    private func stopAll() {
        stopTimers()
        PermissionGuidePanel.shared.close()
    }
}

/// One checklist row: an icon tile, the permission's name and what it buys,
/// and Allow → Waiting… → ✓ Allowed on the right.
private struct PermissionRow: View {
    enum Status { case needed, waiting, allowed }

    /// Where the title starts, for content placed under it.
    static let textInset: CGFloat = VQ.Spacing.m + 34 + VQ.Spacing.s

    let icon: String
    let title: String
    let benefit: String
    let state: Status
    var optional = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: VQ.Spacing.s) {
            RoundedRectangle(cornerRadius: 9)
                .fill(VQ.Colors.fill)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(VQ.Colors.ink)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GTFont.flex(VQ.TypeScale.headline.size, weight: VQ.TypeScale.headline.weight))
                    .foregroundStyle(VQ.Colors.ink)
                Text(benefit)
                    .font(GTFont.flex(VQ.TypeScale.meta.size, weight: VQ.TypeScale.meta.weight))
                    .foregroundStyle(VQ.Colors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: VQ.Spacing.xs)
            trailing
        }
        .padding(.horizontal, VQ.Spacing.m)
        .padding(.vertical, VQ.Spacing.s)
    }

    @ViewBuilder
    private var trailing: some View {
        let label = GTFont.flex(12.5, weight: 600)
        switch state {
        case .needed:
            Button(action: action) {
                Text("Allow")
                    .font(label)
                    .foregroundStyle(optional ? VQ.Colors.ink : VQ.Colors.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(optional ? VQ.Colors.fill : VQ.Colors.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        case .waiting:
            // Clicking it again re-opens the pane, for someone who closed
            // System Settings before finishing.
            Button(action: action) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting…")
                        .font(label)
                        .foregroundStyle(VQ.Colors.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open System Settings again")
        case .allowed:
            Text("✓ Allowed")
                .font(label)
                .foregroundStyle(VQ.Colors.success)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Once the microphone is allowed: is sound actually reaching VoiceiQ? The
/// meter used to have a screen of its own; it now sits under the Microphone row.
private struct MicCheck: View {
    @State private var level: Float = 0
    @State private var meter: AudioCaptureEngine?
    /// Users reported setup picking the wrong input with no way to change it —
    /// the menu bar has had a Microphone submenu all along, but onboarding, the
    /// one place you are actually watching a level meter, did not.
    @State private var inputs: [AudioInputDevices.Device] = []
    @State private var selectedInput: AudioDeviceID?
    /// Counts level callbacks, NOT their value. A live mic in a silent room still
    /// ticks (with level ~0); a device that delivers nothing never ticks at all,
    /// which is the only way to tell "quiet" from "dead" from up here.
    @State private var meterTicks = 0
    @State private var deadDevice = false
    @State private var deadCheck: Timer?
    /// Loudest thing heard since this device was selected. A Bluetooth headset on
    /// the HFP path can be live but so quiet it never reaches speech level —
    /// indistinguishable, from the user's side, from a dead mic.
    @State private var maxLevel: Float = 0
    @State private var settled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: VQ.Spacing.xs) {
                Capsule()
                    .fill(VQ.Colors.fill)
                    .frame(width: 36, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(VQ.Colors.accent)
                            .frame(width: 36 * CGFloat(min(1, level * 2.5)), height: 4)
                    }
                Text(status.text)
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(status.bad ? VQ.Colors.record : VQ.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if inputs.count > 1 {
                SearchablePicker("", selection: Binding(
                    get: { selectedInput ?? AudioInputDevices.currentDefaultID() },
                    set: { newValue in
                        guard let newValue, newValue != selectedInput else { return }
                        selectedInput = newValue
                        // Moves the SYSTEM default, exactly like the menu
                        // bar picker and Control Center — VoiceiQ always
                        // records from the default rather than pinning a
                        // device, which kills the tap on macOS 26.
                        AudioInputDevices.setDefault(id: newValue)
                        // Re-arm: the level meter is bound to whatever was
                        // open when it started, so a switch has to restart
                        // it or the user watches the OLD mic.
                        stopMeter()
                        startMeter()
                    }
                ), options: inputs.map { SearchOption(value: Optional($0.id), name: $0.name) })
                .frame(maxWidth: 240)
                .font(VoiceIQUI.TypeScale.labelSmall())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            inputs = AudioInputDevices.list()
            selectedInput = AudioInputDevices.currentDefaultID()
            startMeter()
        }
        .onDisappear(perform: stopMeter)
        .onReceive(NotificationCenter.default.publisher(for: .onboardingWindowClosed)) { _ in
            stopMeter() // window close bypasses onDisappear (audit #6)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQDefaultInputChanged).receive(on: RunLoop.main)) { _ in
            inputs = AudioInputDevices.list()
            selectedInput = AudioInputDevices.currentDefaultID()
        }
    }

    /// What to tell the user about the input, in plain terms. The bar moves
    /// whether or not anything useful arrives, so the words carry the answer.
    private var status: (text: String, bad: Bool) {
        let name = currentInputName ?? "this input"
        if deadDevice {
            return ("No sound is reaching VoiceiQ from \(name). Pick a different input.", true)
        }
        if maxLevel >= 0.06 {
            return ("Hearing you on \(name).", false)
        }
        if settled {
            return ("Barely hearing anything from \(name). Speak up, or pick a different input.", true)
        }
        return ("Listening on \(name). Say something.", false)
    }

    private var currentInputName: String? {
        let id = selectedInput ?? AudioInputDevices.currentDefaultID()
        return inputs.first { $0.id == id }?.name
    }

    private func startMeter() {
        meterTicks = 0
        deadDevice = false
        maxLevel = 0
        settled = false
        deadCheck?.invalidate()
        // Bluetooth inputs can take a second or two to negotiate before the first
        // buffer lands, so this waits well past the built-in mic's ~270ms.
        deadCheck = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            Task { @MainActor in
                if meterTicks == 0 { deadDevice = true }
                // Past this point "quiet" is a real observation, not just a mic
                // that has not warmed up yet.
                settled = true
                Log.ui.info("mic check on \(currentInputName ?? "?", privacy: .public): \(meterTicks) callbacks, peak \(maxLevel, format: .fixed(precision: 3))")
            }
        }
        let engine = AudioCaptureEngine()
        engine.onLevel = { value in
            Task { @MainActor in
                level = value
                meterTicks += 1
                maxLevel = max(maxLevel, value)
            }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-mic-test.caf")
        try? engine.start(writingTo: scratch)
        meter = engine
    }

    private func stopMeter() {
        // Fire-and-forget: the meter's audio is a scratch file nobody reads, and
        // the screen must never wait on teardown.
        if let engine = meter {
            Task.detached(priority: .utility) { _ = await engine.stop() }
        }
        meter = nil
        deadCheck?.invalidate()
        deadCheck = nil
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-mic-test.caf"))
    }
}

private struct GlobeKeyScreen: View {
    let onNext: () -> Void
    @State private var fixed = !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey
    @State private var pollTimer: Timer?

    var body: some View {
        ScreenScaffold("Make the 🌐 key yours.", "macOS currently uses the Globe key for its own shortcut. One switch and it's your dictation key.") {
            VStack(spacing: VoiceIQUI.Spacing.m) {
                VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
                    Text("In Keyboard settings, set:")
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                    Text("Press 🌐 key to  →  Do Nothing")
                        .font(VoiceIQUI.TypeScale.title())
                        .foregroundStyle(VoiceIQUI.Colors.onSurface)
                }
                .padding(VoiceIQUI.Spacing.m)
                .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).fill(VoiceIQUI.Colors.surface))
                // A white card on the white canvas needs its ring to show.
                .overlay(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).strokeBorder(VQ.Colors.hairline, lineWidth: 1))

                if fixed {
                    Label("Done — the Globe key is yours", systemImage: "checkmark.circle.fill")
                        .font(VoiceIQUI.TypeScale.body())
                        .foregroundStyle(VoiceIQUI.Colors.success)
                } else {
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(FnUsageAdvisor.keyboardSettingsURL)
                    }
                    .buttonStyle(.bordered)
                }

                if FnUsageAdvisor.karabinerIsPresent() {
                    Text("Karabiner-Elements is running — if fn doesn't respond, add VoiceiQ to its exclusions.")
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }

                PrimaryButton(title: fixed ? "Continue" : "Skip for now", action: onNext)
            }
        }
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    fixed = !FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }
}

/// Teach the product, not just prove it works (dogfood): the two gestures,
/// with the user's ACTUAL configured key, before the hands-on Try It.
private struct HowToScreen: View {
    let onNext: () -> Void
    private let keyName = SettingsStore().dictationTrigger.displayName
    private let shortcuts = ShortcutStore()

    var body: some View {
        ScreenScaffold("Talk to VoiceiQ.", "One press starts, one press finishes. Every key is editable in Settings → Dictation.") {
            VStack(spacing: VoiceIQUI.Spacing.m) {
                VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.s) {
                    gestureRow(keys: [keyName], title: "Dictate",
                               detail: "Talk as long as you like. Press \(keyName) again and polished text lands at your cursor.")
                    gestureRow(keys: ["⌘esc"], title: "Changed your mind",
                               detail: "Cancels the dictation. Long recordings are kept in History.")
                    gestureRow(keys: [shortcuts.shortcut(for: .meetingToggle).displayString], title: "Meeting notes",
                               detail: "Records the call, then writes a transcript, summary, and action items.")
                    gestureRow(keys: [shortcuts.shortcut(for: .pasteLastTranscript).displayString], title: "Paste last transcript",
                               detail: "Types the most recent dictation again wherever the cursor is.")
                }
                .padding(VoiceIQUI.Spacing.m)
                .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).fill(VoiceIQUI.Colors.surface)
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 2))
                PrimaryButton(title: "Got it", action: onNext)
            }
        }
    }

    private func gestureRow(keys: [String], title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: VoiceIQUI.Spacing.s) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keycap(key)
                }
            }
            .frame(width: 132, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(VoiceIQUI.Colors.onSurface)
                Text(detail)
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(VoiceIQUI.TypeScale.code)
            .foregroundStyle(VoiceIQUI.Colors.onSurface)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(VoiceIQUI.Colors.surfaceContainer)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(VoiceIQUI.Colors.outlineVariant.opacity(0.6), lineWidth: 1))
            )
    }
}

private struct TryItScreen: View {
    let onNext: () -> Void
    var latestRecord: () -> DictationRecord? = { nil }
    @State private var text = ""
    @State private var celebrated = false
    @State private var revealRaw: String?
    @State private var revealClean: String?
    @State private var fetchTask: Task<Void, Never>?

    private let keyName = SettingsStore().dictationTrigger.displayName
    private var hasWords: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static let script = "Let's schedule the meeting for 1pm — actually, no, make it 2pm."

    var body: some View {
        ScreenScaffold("Try it.", "Click into the field, press \(keyName), and change your mind mid-sentence:") {
            VStack(spacing: VoiceIQUI.Spacing.s) {
                if revealRaw == nil {
                    Text("“\(Self.script)”")
                        .font(VoiceIQUI.TypeScale.body())
                        .italic()
                        .foregroundStyle(VoiceIQUI.Colors.onSurface)
                        .padding(.horizontal, VoiceIQUI.Spacing.m)
                        .padding(.vertical, VoiceIQUI.Spacing.xs)
                        .background(Capsule().fill(VoiceIQUI.Colors.surfaceContainer))
                    Text("(or say anything you like)")
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(VoiceIQUI.TypeScale.bodyLarge())
                        .scrollContentBackground(.hidden)
                        .padding(VoiceIQUI.Spacing.s)
                        .frame(width: 400, height: 96)
                        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).fill(VoiceIQUI.Colors.surface))
                        .overlay(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).strokeBorder(VoiceIQUI.Colors.outlineVariant.opacity(0.4), lineWidth: 1))
                    if text.isEmpty {
                        Text("Your words will land here.")
                            .font(VoiceIQUI.TypeScale.bodyLarge())
                            .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant.opacity(0.6))
                            .padding(VoiceIQUI.Spacing.m)
                            .allowsHitTesting(false)
                    }
                }
                if let raw = revealRaw, let clean = revealClean {
                    // The reveal: what the pipeline actually did to their words —
                    // real record data, shown only when a real difference exists.
                    // The two rows ARE the story — no caption needed.
                    VStack(alignment: .leading, spacing: 3) {
                        revealRow(label: "You said", value: raw, emphasized: false)
                        revealRow(label: "VoiceiQ wrote", value: clean, emphasized: true)
                    }
                    .padding(VoiceIQUI.Spacing.s)
                    .frame(width: 400, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if celebrated {
                    ConfettiBurst()
                        .frame(height: 40)
                    Text("You just dictated \(text.split(separator: " ").count) words. That's the whole trick.")
                        .font(VoiceIQUI.TypeScale.body())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                }
                // Words in the field = the moment to move forward. Skipping is a
                // quiet option only while it's empty (dogfood: "Skip for now"
                // lingering after success wasn't helpful).
                if hasWords {
                    PrimaryButton(title: "Continue", action: onNext)
                } else {
                    Button("Skip for now", action: onNext)
                        .buttonStyle(.plain)
                        .font(VoiceIQUI.TypeScale.body())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                        .padding(.vertical, VoiceIQUI.Spacing.s)
                }
            }
            .animation(VoiceIQMotion.expressiveDefaultSpatial, value: revealRaw)
        }
        .onChange(of: text) { _, newValue in
            if !celebrated, newValue.split(separator: " ").count >= 2 {
                celebrated = true
            }
            if hasWords, fetchTask == nil {
                fetchReveal()
            }
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
        }
    }

    private func revealRow(label: String, value: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VoiceIQUI.Spacing.xs) {
            Text(label)
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .frame(width: 62, alignment: .trailing)
            Text(value)
                .font(emphasized ? VoiceIQUI.TypeScale.body() : VoiceIQUI.TypeScale.labelSmall())
                .italic(!emphasized)
                .foregroundStyle(emphasized ? VoiceIQUI.Colors.onSurface : VoiceIQUI.Colors.onSurfaceVariant)
                .lineLimit(2)
        }
    }

    /// The record lands moments after the text does — fetch with one retry, and
    /// only show the card when their words genuinely changed.
    ///
    /// The left-hand row used to be `record.rawTranscript`, which worked only
    /// while a second model did the cleanup — with native smart transcription
    /// raw and cleaned are the same string, the predicate is always false, and
    /// the single best moment in onboarding silently stops happening.
    ///
    /// So the reference is now the script this screen already put in front of
    /// them, used only when they actually read it. That is both honest and a
    /// stronger demo: the left row is the messy sentence they were asked to say,
    /// the right row is what landed. Falls back to the raw≠clean rule when they
    /// said something of their own.
    private func fetchReveal() {
        fetchTask = Task { @MainActor in
            for delay in [0.4, 1.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let record = latestRecord(),
                      let clean = record.cleanedTranscript, !clean.isEmpty else { continue }

                if let raw = record.rawTranscript, Self.normalized(raw) != Self.normalized(clean) {
                    revealRaw = raw
                    revealClean = clean
                    return
                }
                // They read the script: show it against what VoiceiQ wrote, but only
                // if the result is actually shorter — otherwise there is no
                // change of mind to reveal and the celebration is the honest UI.
                if Self.readTheScript(clean), clean.count < Self.script.count {
                    revealRaw = Self.script
                    revealClean = clean
                    return
                }
            }
        }
    }

    /// Did they say roughly the scripted sentence? Compared on the tail — the
    /// script's ending ("make it 2pm") survives cleanup, while its middle is
    /// exactly what gets collapsed away.
    private static func readTheScript(_ cleaned: String) -> Bool {
        let words = normalized(cleaned).split(separator: " ")
        guard words.count >= 3 else { return false }
        return normalized(cleaned).contains("2pm") || normalized(cleaned).contains("2 pm")
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct DoneScreen: View {
    let onFinish: () -> Void
    // Default ON — consent by visibility; the finish handler reconciles against
    // the real SMAppService state, so unchecking on a re-run actually disables.
    @State private var launchAtLogin = true

    var body: some View {
        ScreenScaffold("You're set.", "VoiceiQ lives in your menu bar now. Press \(SettingsStore().dictationTrigger.displayName) anywhere and start talking.") {
            VStack(spacing: VoiceIQUI.Spacing.m) {
                // Same voice as the scaffold's subtitle — two type sizes on the
                // page total (display + body), never three.
                // "strips your ums" read as jargon to a first-time user (Kat,
                // from the wild) — name the filler words plainly instead.
                Text("It removes filler words like \"umm\" and \"uhh\", follows your change of mind, and turns spoken lists into lists. Words you correct after pasting are learned into Settings → Dictionary.")
                    .font(VoiceIQUI.TypeScale.body())
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
                Toggle("Start VoiceiQ at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                PrimaryButton(title: "Start dictating") {
                    let enabled = SMAppService.mainApp.status == .enabled
                    do {
                        if launchAtLogin, !enabled {
                            try SMAppService.mainApp.register()
                        } else if !launchAtLogin, enabled {
                            // Re-run onboarding + uncheck must actually disable it.
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Dev/translocated builds throw routinely — never block
                        // finishing onboarding on the login item.
                        Log.ui.error("onboarding launch-at-login failed: \(error)")
                    }
                    onFinish()
                }
            }
        }
    }
}

/// Four-color confetti — onboarding only (Reduce Motion gets a static card).
private struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        if reduceMotion {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(VoiceIQUI.Colors.brandQuad[i]).frame(width: 8, height: 8)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack {
                    ForEach(0..<24, id: \.self) { i in
                        Circle()
                            .fill(VoiceIQUI.Colors.brandQuad[i % 4])
                            .frame(width: 6, height: 6)
                            .offset(
                                x: animate ? CGFloat((i * 37) % 200) - 100 : 0,
                                y: animate ? CGFloat((i * 23) % 60) - 40 : 0
                            )
                            .opacity(animate ? 0 : 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.2)) {
                    animate = true
                }
            }
        }
    }
}

import ServiceManagement
