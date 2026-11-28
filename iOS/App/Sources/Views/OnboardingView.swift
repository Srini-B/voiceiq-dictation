import SwiftUI

/// Intro slides, then setup: a model key, the microphone, the keyboard in
/// Settings, switching to it, and a field to try it in. Each setup page
/// watches `SetupMonitor`: when what it asks for is done, it shows the check
/// and moves on by itself. The page is saved as the user moves, because iOS
/// may end the app while they are in Settings.
struct OnboardingView: View {
    let onFinished: () -> Void
    @EnvironmentObject private var setup: SetupMonitor
    @State private var step = Step(rawValue: MobileSettings.onboardingStep) ?? .intro
    @State private var forward = true
    /// Bumped each time a page's setup completes, for the success haptic.
    @State private var completions = 0
    /// The CTAs hide while typing: with the keyboard's Done bar above them they
    /// covered the field the scroll view had just brought into view.
    @State private var keyboardShown = false

    enum Step: Int, CaseIterable {
        case intro, keys, microphone, addKeyboard, switchKeyboard, tryIt

        /// Whether what this page asks for is done. Pages the user finishes by
        /// tapping Continue are never done on their own.
        func isDone(_ status: SetupStatus) -> Bool {
            switch self {
            case .microphone: return status.micGranted
            case .addKeyboard: return status.keyboardAdded
            // The keyboard reports in only once it has run with Full Access,
            // so one signal proves both.
            case .switchKeyboard: return status.fullAccess
            case .intro, .keys, .tryIt: return false
            }
        }
    }

    var body: some View {
        Group {
            if step == .intro {
                IntroSlides(onFinished: advance)
                    .transition(.opacity)
            } else {
                setupPages
            }
        }
        .background(Theme.Colors.canvas.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        .onAppear { setup.refresh() }
        // A page whose setup is already done when the user moves forward onto
        // it, or that gets done while it shows, checks off and moves on. Going
        // back to it stays put, so Back is never undone.
        .task(id: AutoAdvance(step: step, done: step.isDone(setup.status), forward: forward)) {
            guard step.isDone(setup.status), forward else { return }
            completions += 1
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            advance()
        }
        .sensoryFeedback(.success, trigger: completions)
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private struct AutoAdvance: Equatable {
        let step: Step
        let done: Bool
        let forward: Bool
    }

    private var setupPages: some View {
        VStack(spacing: 0) {
            OnboardingHeader(step: step.rawValue, total: Step.allCases.count - 1, back: back)
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, Theme.Spacing.s)
                .readableWidth(560)
            ScrollView {
                page
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.top, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)
                    .readableWidth(560)
            }
            .scrollBounceBehavior(.basedOnSize)
            .keyboardDismissable()
            if !keyboardShown {
                footer
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.top, Theme.Spacing.m)
                    .padding(.bottom, Theme.Spacing.s)
                    .readableWidth(560)
            }
        }
        .onTapGesture { UIApplication.shared.endEditing() }
    }

    @ViewBuilder private var page: some View {
        Group {
            switch step {
            case .intro: EmptyView()
            case .keys: KeysPage()
            case .microphone: MicrophonePage()
            case .addKeyboard: AddKeyboardPage()
            case .switchKeyboard: SwitchKeyboardPage()
            case .tryIt: TryItPage()
            }
        }
        .id(step)
        .transition(.asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        ))
    }

    @ViewBuilder private var footer: some View {
        let status = setup.status
        VStack(spacing: Theme.Spacing.s) {
            switch step {
            case .intro:
                EmptyView()
            case .keys:
                Button("Continue", action: advance).buttonStyle(.primaryPill)
                    .disabled(!status.hasKey)
                if !status.hasKey {
                    Button("Add a key later", action: advance).buttonStyle(.secondaryPill)
                }
            case .microphone:
                if status.micGranted {
                    Button("Continue", action: advance).buttonStyle(.primaryPill)
                } else if status.micDenied {
                    Button("Open Settings", action: openAppSettings).buttonStyle(.primaryPill)
                    Button("Set up later", action: advance).buttonStyle(.secondaryPill)
                } else {
                    Button("Allow microphone", action: setup.requestMicrophone).buttonStyle(.primaryPill)
                    Button("Not now", action: advance).buttonStyle(.secondaryPill)
                }
            case .addKeyboard:
                if status.keyboardAdded {
                    Button("Continue", action: advance).buttonStyle(.primaryPill)
                } else {
                    Button("Open VoiceiQ Settings", action: openAppSettings).buttonStyle(.primaryPill)
                    // Without the keyboard the last two pages have nothing to
                    // show; Home's Finish setup card picks it up later.
                    Button("Set up later", action: finish).buttonStyle(.secondaryPill)
                }
            case .switchKeyboard:
                Button(status.fullAccess ? "Continue" : "Skip for now", action: advance)
                    .buttonStyle(PillButtonStyle(kind: status.fullAccess ? .primary : .secondary))
            case .tryIt:
                Button("Start using VoiceiQ", action: finish).buttonStyle(.primaryPill)
            }
        }
    }

    private func advance() {
        UIApplication.shared.endEditing()
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        forward = true
        step = next
        MobileSettings.onboardingStep = next.rawValue
    }

    private func back() {
        UIApplication.shared.endEditing()
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        step = previous
        MobileSettings.onboardingStep = previous.rawValue
    }

    private func finish() {
        MobileSettings.onboardingStep = 0
        onFinished()
    }
}

/// VoiceiQ's page in the Settings app, where its Keyboards and permission
/// switches are.
@MainActor func openAppSettings() {
    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
}

/// Back button and a segmented bar: one segment per setup page, filled up to
/// the current one.
private struct OnboardingHeader: View {
    let step: Int
    let total: Int
    let back: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.Colors.porcelain))
            }
            .accessibilityLabel("Back")
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.Colors.accent : Theme.Colors.hairline)
                        .frame(height: 4)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step) of \(total)")
            Color.clear.frame(width: 36, height: 36)
        }
    }
}

// MARK: - Pages

private struct KeysPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            PageTitle(title: "Connect a model", detail: "VoiceiQ runs on your own API key.")
            ModelKeysForm()
        }
    }
}

private struct MicrophonePage: View {
    @EnvironmentObject private var setup: SetupMonitor

    var body: some View {
        let status = setup.status
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            PageTitle(title: "Allow the microphone",
                      detail: "VoiceiQ listens only while you dictate or record a note.")
            MicrophoneMark(granted: status.micGranted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.l)
            Card {
                if status.micDenied {
                    CheckLine(title: "Microphone is off",
                              detail: "Turn on Microphone in VoiceiQ’s page in Settings. VoiceiQ sees it when you come back.",
                              done: false, waiting: true)
                } else {
                    CheckLine(title: status.micGranted ? "Microphone allowed" : "Microphone not allowed yet",
                              done: status.micGranted)
                }
            }
            LiveActivitiesOffCard()
        }
    }
}

private struct AddKeyboardPage: View {
    @EnvironmentObject private var setup: SetupMonitor

    var body: some View {
        let status = setup.status
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            PageTitle(title: "Add the VoiceiQ keyboard",
                      detail: "Two switches in Settings. Open VoiceiQ’s page there, then come back: this page checks itself off.")
            KeyboardSettingsWalkthrough()
            Card {
                CheckLine(title: status.keyboardAdded ? "VoiceiQ keyboard added" : "VoiceiQ keyboard not added yet",
                          done: status.keyboardAdded)
                CheckLine(title: "Allow Full Access",
                          detail: status.fullAccess ? nil : "iOS lets VoiceiQ see this only from its keyboard, so it’s checked on the next page.",
                          done: status.fullAccess,
                          waiting: status.keyboardAdded && !status.fullAccess)
            }
            FullAccessPrivacyNote()
        }
    }
}

private struct SwitchKeyboardPage: View {
    @EnvironmentObject private var setup: SetupMonitor
    @State private var text = ""
    @FocusState private var focused: Bool
    /// When the user last changed keyboards in the field. A switch with no
    /// word from the VoiceiQ keyboard after it means Full Access is off, or
    /// another keyboard was picked.
    @State private var switchedAt: Date?

    var body: some View {
        let status = setup.status
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            (Text("Hold ") + Text(Image(systemName: "globe")) + Text(" to switch to VoiceiQ"))
                .font(Theme.Fonts.title())
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Hold the globe key to switch to VoiceiQ")
            GlobeSwitchDemo()
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                TextField("Tap here, then hold the globe key", text: $text, axis: .vertical)
                    .font(Theme.Fonts.body())
                    .lineLimit(1...3)
                    .focused($focused)
                    .padding(Theme.Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).fill(Theme.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .strokeBorder(focused ? Theme.Colors.accent : Theme.Colors.hairline, lineWidth: focused ? 1.5 : 0.5))
                Text("Or tap \(Image(systemName: "globe")) until VoiceiQ comes up.")
                    .font(Theme.Fonts.footnote())
                    .foregroundStyle(Theme.Colors.muted)
            }
            Card {
                CheckLine(title: "VoiceiQ keyboard in use", done: status.fullAccess)
                CheckLine(title: "Full Access on", done: status.fullAccess)
            }
            if !status.fullAccess, let switchedAt {
                TimelineView(.periodic(from: switchedAt, by: 1)) { context in
                    if context.date.timeIntervalSince(switchedAt) > 4 {
                        noCheckHint
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextInputMode.currentInputModeDidChangeNotification)) { _ in
            switchedAt = Date()
        }
    }

    private var noCheckHint: some View {
        Card {
            Label {
                Text("On the VoiceiQ keyboard but no checks here? Turn on **Allow Full Access** in VoiceiQ › Keyboards in Settings.")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.Colors.pending)
            }
            .font(Theme.Fonts.footnote())
            .foregroundStyle(Theme.Colors.ink)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open VoiceiQ Settings", action: openAppSettings).buttonStyle(.compactSecondary)
        }
        .transition(.opacity)
    }
}

private struct TryItPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            (Text("Tap ") + Text(Image(systemName: "mic.fill")) + Text(" and talk"))
                .font(Theme.Fonts.title())
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityLabel("Tap the mic and talk")
            TryItCard()
            if UIDevice.isPad {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    GroupLabel(text: "Hardware keyboard")
                    Card { HardwareKeyboardSteps() }
                }
            }
        }
    }
}

/// The microphone in a soft halo that breathes until access is granted, then
/// turns into a check.
private struct MicrophoneMark: View {
    let granted: Bool
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tint = granted ? Theme.Colors.success : Theme.Colors.accent
        ZStack {
            ForEach(0..<2, id: \.self) { ring in
                Circle()
                    .fill(tint.opacity(0.08))
                    .frame(width: 112 + CGFloat(ring) * 44, height: 112 + CGFloat(ring) * 44)
                    .scaleEffect(breathing && !granted ? 1.08 : 1)
            }
            Circle().fill(tint).frame(width: 92, height: 92)
            Image(systemName: granted ? "checkmark" : "mic.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityHidden(true)
    }
}
