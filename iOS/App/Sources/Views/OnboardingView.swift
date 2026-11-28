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

/// A round back button and a thin bar filled to the current setup page.
private struct OnboardingHeader: View {
    let step: Int
    let total: Int
    let back: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Colors.ink)
                    .frame(width: 38, height: 38)
                    .overlay(Circle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
                    .contentShape(Circle())
            }
            .accessibilityLabel("Back")
            Capsule()
                .fill(Theme.Colors.porcelain)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Theme.Colors.ink)
                            .frame(width: proxy.size.width * CGFloat(step) / CGFloat(total))
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: step)
                .accessibilityElement()
                .accessibilityLabel("Step \(step) of \(total)")
            Color.clear.frame(width: 38, height: 38)
        }
    }
}

/// A setup page's title in the display face, with one muted line under it.
private struct StepTitle: View {
    let title: Text
    var detail: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            title
                .font(Theme.Fonts.display())
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                detail
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Pages

private struct KeysPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            StepTitle(title: Text("Connect a model"), detail: Text("VoiceiQ runs on your own API key."))
            ModelKeysForm()
        }
    }
}

private struct MicrophonePage: View {
    @EnvironmentObject private var setup: SetupMonitor

    var body: some View {
        let status = setup.status
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            StepTitle(title: Text("Allow the microphone"),
                      detail: Text("VoiceiQ listens only while you talk to it."))
            MicrophoneMark(granted: status.micGranted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.l)
            Card {
                SetupCheckRow(symbol: "mic",
                              title: "Dictate with your voice",
                              detail: status.micDenied
                                  ? "The microphone is off. Turn it on in VoiceiQ’s page in Settings."
                                  : "Used only while you dictate or record a note.",
                              state: status.micGranted ? .done("Allowed") : .todo)
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
            StepTitle(title: Text("Add the keyboard"),
                      detail: Text("Two switches in Settings. Come back and this page checks itself."))
            KeyboardSettingsWalkthrough()
            Card {
                SetupCheckRow(symbol: "keyboard",
                              title: "VoiceiQ in every app",
                              detail: "The VoiceiQ keyboard, added in Settings.",
                              state: status.keyboardAdded ? .done("Added") : .todo)
                Divider()
                SetupCheckRow(symbol: "lock.open",
                              title: "Dictation from the keyboard",
                              detail: "Allow Full Access. iOS shows it to VoiceiQ when the keyboard first opens, on the next page.",
                              state: status.fullAccess ? .done("Allowed") : status.keyboardAdded ? .waiting : .todo)
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
            StepTitle(title: Text("Hold \(Image(systemName: "globe")) to switch"),
                      detail: Text("Then pick VoiceiQ. Or tap \(Image(systemName: "globe")) until it comes up."))
            GlobeSwitchDemo()
            TextField("Tap here, then hold the globe key", text: $text, axis: .vertical)
                .font(Theme.Fonts.body())
                .lineLimit(1...3)
                .focused($focused)
                .padding(Theme.Spacing.m)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).fill(Theme.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(focused ? Theme.Colors.accent : Theme.Colors.hairline, lineWidth: focused ? 1.5 : 1))
            Card {
                SetupCheckRow(symbol: "character.cursor.ibeam",
                              title: "Dictate where you type",
                              detail: "The VoiceiQ keyboard, in use.",
                              state: status.fullAccess ? .done("In use") : .waiting)
                Divider()
                SetupCheckRow(symbol: "lock.open",
                              title: "Dictation from the keyboard",
                              detail: "Allow Full Access.",
                              state: status.fullAccess ? .done("Allowed") : .waiting)
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
                Text("On the VoiceiQ keyboard but nothing ticked? Turn on **Allow Full Access** in VoiceiQ › Keyboards in Settings.")
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.Colors.pending)
            }
            .font(Theme.Fonts.callout())
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
            StepTitle(title: Text("Try it"), detail: Text("Tap the Talk key and say something."))
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

/// The microphone in hairline rings that breathe until access is granted,
/// then a check in success green.
private struct MicrophoneMark: View {
    let granted: Bool
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
                    .frame(width: 96 + CGFloat(ring) * 40, height: 96 + CGFloat(ring) * 40)
                    .scaleEffect(breathing && !granted ? 1 + 0.04 * CGFloat(ring + 1) : 1)
            }
            Circle()
                .strokeBorder(granted ? Theme.Colors.success : Theme.Colors.inkSecondary, lineWidth: 1.5)
                .frame(width: 88, height: 88)
            Image(systemName: granted ? "checkmark" : "mic")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(granted ? Theme.Colors.success : Theme.Colors.inkSecondary)
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
