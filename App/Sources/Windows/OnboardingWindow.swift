import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import VoiceIQCore

/// First-launch onboarding: welcome → key → mic → accessibility → Globe key →
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
        // Setup sends people into System Settings twice (microphone, then
        // accessibility), and every trip steals focus. VoiceiQ is an accessory app,
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

    enum Screen: Int, CaseIterable {
        case welcome, apiKey, microphone, accessibility, globeKey, howTo, tryIt, done
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
        .background(VoiceIQUI.Colors.windowBackground)
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
        case .microphone: MicScreen(onNext: { advance() })
        case .accessibility: AccessibilityScreen(onNext: { advance() })
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
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
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

private struct PermissionCard: View {
    let icon: String
    let title: String
    let granted: Bool
    var actionTitle = "Grant"
    let action: () -> Void

    var body: some View {
        HStack(spacing: VoiceIQUI.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? VoiceIQUI.Colors.success : VoiceIQUI.Colors.primary)
                .frame(width: 28)
            Text(title)
                .font(VoiceIQUI.TypeScale.body())
                .foregroundStyle(VoiceIQUI.Colors.onSurface)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(VoiceIQUI.Colors.success)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(VoiceIQUI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).fill(VoiceIQUI.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.large).strokeBorder(VoiceIQUI.Colors.outlineVariant.opacity(0.3), lineWidth: 1))
        .animation(VoiceIQMotion.expressiveFastSpatial, value: granted)
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
    /// The key authenticates but reaches no transcription model — say so here
    /// rather than letting them discover it on their first dictation.
    @State private var noModelAccess = false
    /// Set when the server actively rejected the key, so we can say so instead of
    /// the generic "didn't work".
    @State private var rejection: String?
    /// The check could not be performed. We let them past, but we say so.
    @State private var unverified = false
    /// Replacing a key that is already stored — bug report: a user who saved a
    /// bad key had to UNINSTALL the app to get another chance at this screen.
    @State private var replacing = false
    @State private var provider = SettingsStore().preferredProvider
    /// A saved key for the selected provider completes this step.
    @State private var storedKeyExists = KeychainStore.hasKey(for: SettingsStore().preferredProvider)
    private var showingField: Bool { !storedKeyExists || replacing }
    private var host: String { provider == .gemini ? "Google" : "OpenAI" }

    var body: some View {
        ScreenScaffold("Bring your own key.", "VoiceiQ uses your \(provider.displayName) API key. It's stored in your Mac's Keychain and only ever sent to \(host).") {
            VStack(spacing: VoiceIQUI.Spacing.s) {
                Picker("Provider", selection: $provider) {
                    ForEach(ModelProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .disabled(validating)
                .onChange(of: provider) { _, value in
                    SettingsStore().setPreferredProvider(value)
                    storedKeyExists = KeychainStore.hasKey(for: value)
                    replacing = false
                    key = ""
                    failed = false
                    rejection = nil
                    unverified = false
                    noModelAccess = false
                }
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
                        noModelAccess = false
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
                             ?? "That key didn't work — check it in \(provider == .gemini ? "AI Studio" : "your OpenAI dashboard").")
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VoiceIQUI.Colors.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }
                    if unverified {
                        Text("Couldn't reach \(host) to check this key — saved it anyway. Your first dictation will tell you for sure.")
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
                    if noModelAccess {
                        Text("That key works, but it can't reach VoiceiQ's transcription model yet. Setup continues — ask for access, then try a dictation.")
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(VoiceIQUI.Colors.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if provider == .gemini {
                        Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(VoiceIQUI.TypeScale.labelSmall())
                    } else {
                        Link("Get a key from OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(VoiceIQUI.TypeScale.labelSmall())
                    }
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
        let provider = provider
        Task {
            let client = provider == .gemini
                ? GeminiClient(apiKey: { candidate })
                : GeminiClient(apiKey: { nil }, openAIKey: { candidate })
            let check = provider == .gemini
                ? await client.validateKey(endpoint: SettingsStore().geminiConfig.endpoint)
                : await client.validateOpenAIKey()

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

            if check == .valid, provider == .gemini {
                // "Your key works" must mean dictation works. Check the model
                // VoiceiQ actually ships on — and only report, never substitute.
                let config = SettingsStore().geminiConfig
                noModelAccess = await client.resolveAvailableModel(
                    from: [config.transcribeModel], endpoint: config.endpoint
                ) == nil
            }
            unverified = (check == .unreachable)

            let saved = provider == .gemini ? KeychainStore.saveAPIKey(candidate) : KeychainStore.saveOpenAIKey(candidate)
            guard saved else {
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

private struct MicScreen: View {
    let onNext: () -> Void
    @State private var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var level: Float = 0
    @State private var meterLevel = LevelSource()
    @State private var meter: AudioCaptureEngine?
    @State private var heard = false
    @State private var advancing = false
    @State private var speechFrames = 0
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
    /// the HFP path can be live but so quiet it never reaches the "heard you"
    /// threshold — indistinguishable, from the user's side, from a dead mic,
    /// because the waveform idles either way.
    @State private var maxLevel: Float = 0
    @State private var settled = false
    /// macOS asks ONCE per install. After a denial the prompt never reappears,
    /// so the button must stop pretending and send the user to System Settings.
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted

    // "Can we listen?" read as surveillance (dogfood). This screen is a mic
    // CHECK, so it behaves like one: say hello, VoiceiQ hears you, it moves on.
    private var headline: String {
        if granted { return "Say hello." }
        return denied ? "The mic is switched off." : "Turn on the mic."
    }
    private var sub: String {
        if heard { return "Heard you loud and clear." }
        if granted { return "VoiceiQ is listening — this just checks your mic." }
        return denied
            ? "macOS only asks once. Turn VoiceiQ on under Privacy & Security → Microphone, then come back."
            : "macOS asks once. VoiceiQ only ever records while you're dictating."
    }

    var body: some View {
        ScreenScaffold(headline, sub) {
            VStack(spacing: VoiceIQUI.Spacing.m) {
                if granted {
                    ZStack {
                        WaveformView(level: meterLevel, processing: false)
                            .opacity(heard ? 0 : 1)
                        if heard {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(VoiceIQUI.Colors.success)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 200, height: 48)
                    .background(Capsule().fill(VoiceIQUI.Colors.surface).shadow(color: .black.opacity(0.15), radius: 10, y: 2))
                    .animation(VoiceIQMotion.expressiveDefaultSpatial, value: heard)
        .animation(VoiceIQMotion.defaultEffects, value: maxLevel >= 0.06)
                    .onAppear(perform: startMeter)
                    .onDisappear(perform: stopMeter)
                    .onReceive(NotificationCenter.default.publisher(for: .onboardingWindowClosed)) { _ in
                        stopMeter() // window close bypasses onDisappear (audit #6)
                    }
                    // Always say what the mic is doing. The waveform breathes
                    // whether or not anything is arriving, so on its own it can
                    // never answer "is this working?".
                    if let status = micStatus {
                        Text(status.text)
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(status.bad ? VoiceIQUI.Colors.error : VoiceIQUI.Colors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 340)
                            .transition(.opacity)
                    }
                    if inputs.count > 1 {
                        Picker("", selection: Binding(
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
                                heard = false
                                speechFrames = 0
                                stopMeter()
                                startMeter()
                            }
                        )) {
                            ForEach(inputs) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                    }

                    // Speaking IS the continue gesture; the quiet link remains for
                    // silent environments and users who can't speak.
                    Button("Continue without speaking") { advance() }
                        .buttonStyle(.plain)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                } else {
                    PermissionCard(
                        icon: "mic.fill",
                        title: "Microphone",
                        granted: granted,
                        actionTitle: denied ? "Open Settings" : "Grant"
                    ) {
                        if denied {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        } else {
                            AVCaptureDevice.requestAccess(for: .audio) { ok in
                                Task { @MainActor in
                                    granted = ok
                                    denied = !ok
                                }
                            }
                        }
                    }
                    // Never a dead end: setup continues, and the menu bar keeps
                    // saying what is still missing.
                    Button("Skip for now", action: { advance() })
                        .buttonStyle(.plain)
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                }
            }
        }
        .onAppear {
            inputs = AudioInputDevices.list()
            selectedInput = AudioInputDevices.currentDefaultID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQDefaultInputChanged).receive(on: RunLoop.main)) { _ in
            inputs = AudioInputDevices.list()
            selectedInput = AudioInputDevices.currentDefaultID()
        }
        .onChange(of: level) { _, value in
            // Sustained speech energy, not a door slam or chair scrape: ~150ms
            // above the speech threshold before it counts as "hello".
            guard !heard else { return }
            if value > 0.18 {
                speechFrames += 1
                if speechFrames >= 7 {
                    heard = true
                    advance(after: 0.9)
                }
            } else {
                speechFrames = max(0, speechFrames - 1)
            }
        }
    }

    private func advance(after delay: TimeInterval = 0) {
        guard !advancing else { return }
        advancing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            stopMeter()
            onNext()
        }
    }

    /// What to tell the user about the input, in plain terms.
    private var micStatus: (text: String, bad: Bool)? {
        guard !heard else { return nil }
        let name = currentInputName ?? "this input"
        if deadDevice {
            return ("No sound is reaching VoiceiQ from \(name). Pick a different input below.", true)
        }
        if maxLevel >= 0.06 {
            // Something is definitely arriving — say so, even before it is loud
            // enough to count as "hello".
            return ("Picking up sound from \(name) — keep going.", false)
        }
        if settled {
            return ("Barely hearing anything from \(name). Speak up, or pick a different input below.", true)
        }
        return ("Listening on \(name)…", false)
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
                meterLevel.value = value
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

private struct AccessibilityScreen: View {
    let onNext: () -> Void
    @State private var granted = AXIsProcessTrusted()
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var pollTimer: Timer?
    @State private var slowGrant = false

    var body: some View {
        ScreenScaffold("Let it type for you.", "Accessibility places text at your cursor. Screen Recording lets VoiceiQ read names and paths on screen while you talk. It is optional.") {
            VStack(spacing: VoiceIQUI.Spacing.m) {
                PermissionCard(icon: "keyboard", title: "Accessibility", granted: granted) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                PermissionCard(icon: "rectangle.dashed.badge.record", title: "Screen Recording", granted: screenGranted) {
                    if !CGRequestScreenCaptureAccess() {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                if slowGrant && !granted {
                    Text("Granted but not detected? A relaunch may be needed.")
                        .font(VoiceIQUI.TypeScale.labelSmall())
                        .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                }
                PrimaryButton(title: "Continue", disabled: !granted, action: onNext)
            }
        }
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    let trusted = AXIsProcessTrusted()
                    if trusted, !granted {
                        // Wake the engine NOW — otherwise the Try-It screen two
                        // steps later is dead until relaunch (production pass 2).
                        NotificationCenter.default.post(name: .gtSettingDidChange, object: "accessibility")
                        // They are standing in System Settings right now. Bring
                        // the flow back so the next step is in front of them
                        // rather than behind whatever they were just using.
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    granted = trusted
                    screenGranted = CGPreflightScreenCaptureAccess()
                }
            }
            Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
                Task { @MainActor in slowGrant = true }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
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
                    gestureRow(keys: ["esc"], title: "Changed your mind",
                               detail: "Cancels the dictation. Long recordings are kept in History.")
                    gestureRow(keys: [shortcuts.shortcut(for: .askAnything).displayString], title: "Ask Anything",
                               detail: "Speak a question or a command over selected text. The answer shows on the pill.")
                    gestureRow(keys: [shortcuts.shortcut(for: .translate).displayString], title: "Translate",
                               detail: "Speak in any language. The target language types out.")
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
