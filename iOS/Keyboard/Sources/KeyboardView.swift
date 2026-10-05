import SwiftUI
import UIKit
import VoiceIQBridge

private enum KeyboardPalette {
    static let accentUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.341, green: 0.525, blue: 0.941, alpha: 1)
            : UIColor(red: 0.133, green: 0.322, blue: 0.737, alpha: 1)
    }
    static let accent = Color(accentUIColor)
    static let recording = Color(red: 0.92, green: 0.26, blue: 0.21)
    static let keyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray4 : .systemBackground
    }
    static let key = Color(keyUIColor)
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @ObservedObject var offer: DictionaryOffer
    let controller: KeyboardViewController

    var body: some View {
        VStack(spacing: 8) {
            if let answer = model.answer {
                AnswerPanel(answer: answer, model: model)
            } else {
                ModePicker(
                    mode: $model.mode,
                    locked: model.phase == .recording || model.phase == .processing
                )
                Spacer(minLength: 0)
                center
                Spacer(minLength: 0)
            }
            bottomRow
        }
        .padding(8)
    }

    @ViewBuilder private var center: some View {
        if !model.hasFullAccess {
            VStack(spacing: 8) {
                Button("Allow Full Access") { model.micTapped() }
                    .buttonStyle(PrimaryPillStyle())
                Text("Settings › VoiceiQ › Keyboards")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    cancelSlot
                    MicBar(
                        phase: model.phase,
                        waiting: model.waitingForApp,
                        level: model.level,
                        title: micTitle,
                        action: model.micTapped
                    )
                    .frame(maxWidth: 300)
                    Color.clear.frame(width: 36, height: 36)
                }
                .frame(maxWidth: .infinity)

                Group {
                    if let notice = model.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(KeyboardPalette.recording)
                            .lineLimit(1)
                    } else if model.phase == .off || model.phase == .warm {
                        DictionaryOfferChip(offer: offer)
                    }
                }
                .frame(height: DictionaryOfferChip.height)
            }
        }
    }

    @ViewBuilder private var cancelSlot: some View {
        if model.phase == .recording {
            Button(action: model.cancelTapped) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.secondarySystemFill)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Cancel")
        } else {
            Color.clear.frame(width: 36, height: 36)
        }
    }

    private var micTitle: String {
        if model.waitingForApp, model.phase != .recording { return "Starting…" }
        switch model.phase {
        case .recording: return "Tap to finish"
        case .processing: return model.mode == .ask ? "Thinking…" : "Writing…"
        case .warm, .off:
            switch model.mode {
            case .dictate: return "Tap to speak"
            case .translate: return "Tap to translate"
            case .ask: return "Tap to ask"
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobeKey {
                GlobeKey(controller: controller).frame(width: 44)
            }
            KeyCap(systemImage: "doc.on.clipboard", label: "Paste last", enabled: model.lastText != nil) {
                model.pasteLast()
            }
            .frame(width: 44)
            KeyCap(title: "space") { model.insertSpace() }
            RepeatingKey(action: model.deleteBackward).frame(width: 52)
            KeyCap(systemImage: "return", label: "Return") { model.insertReturn() }
                .frame(width: 52)
        }
        .frame(height: 42)
    }
}

private struct ModePicker: View {
    @Binding var mode: KeyboardMode
    let locked: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(KeyboardMode.allCases, id: \.self) { item in
                Button {
                    mode = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if mode == item {
                                Capsule().fill(KeyboardPalette.accent.opacity(0.16))
                            }
                        }
                        .foregroundStyle(mode == item ? KeyboardPalette.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(locked)
            }
        }
        .padding(2)
        .frame(width: 286, height: 32)
        .background(Capsule().fill(Color(.secondarySystemFill)))
        .opacity(locked ? 0.7 : 1)
        .frame(maxWidth: .infinity)
    }
}

private struct MicBar: View {
    let phase: SessionSnapshot.Phase
    let waiting: Bool
    let level: Float
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leadingContent
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(foregroundColor)
            .background(Capsule().fill(fillColor))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(MicBarButtonStyle())
        .accessibilityLabel(phase == .recording ? "Stop" : "Dictate")
    }

    @ViewBuilder private var leadingContent: some View {
        if phase == .recording {
            RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 12, height: 12)
            Waveform(level: level)
        } else if phase == .processing || waiting {
            ProgressView().tint(phase == .processing ? KeyboardPalette.accent : .white)
        } else {
            Image(systemName: "mic.fill").font(.system(size: 18, weight: .semibold))
        }
    }

    private var fillColor: Color {
        switch phase {
        case .recording: return KeyboardPalette.recording
        case .processing: return Color(.secondarySystemFill)
        case .warm, .off: return KeyboardPalette.accent
        }
    }

    private var foregroundColor: Color {
        phase == .processing ? .primary : .white
    }
}

private struct Waveform: View {
    let level: Float
    private let pattern: [CGFloat] = [0.45, 0.7, 0.35, 0.9, 0.55, 1, 0.42, 0.78, 0.58, 0.88, 0.4, 0.68, 0.95, 0.5, 0.82, 0.38, 0.72, 0.52]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pattern.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 2, height: barHeight(index))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let energy = 0.25 + CGFloat(min(max(level, 0), 1)) * 0.75
        return max(4, 24 * pattern[index] * energy)
    }
}

private struct AnswerPanel: View {
    let answer: Delivery
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                Text(answer.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Close", action: model.dismissAnswer).buttonStyle(AnswerButtonStyle())
                Spacer()
                Button("Copy", action: model.copyAnswer).buttonStyle(AnswerButtonStyle())
                Button("Insert", action: model.insertAnswer).buttonStyle(AnswerButtonStyle(primary: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

private struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Capsule().fill(KeyboardPalette.accent.opacity(configuration.isPressed ? 0.82 : 1)))
    }
}

private struct AnswerButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(primary ? KeyboardPalette.accent : Color(.secondarySystemFill)))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct MicBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct KeyCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(KeyboardPalette.key.opacity(configuration.isPressed ? 0.72 : 1))
            )
            .shadow(color: .black.opacity(0.28), radius: 0, y: 1)
            .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

private struct KeyCap: View {
    var title: String?
    var systemImage: String?
    var label: String?
    var enabled = true
    let action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    init(systemImage: String, label: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Image(systemName: systemImage) } else { Text(title ?? "") }
            }
            .font(.system(size: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(KeyCapStyle())
        .foregroundStyle(.primary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label ?? title ?? "")
    }
}

/// A UIKit key that matches the SwiftUI keycaps: rounded, raised by a soft
/// shadow, a shade darker while pressed.
private func makeUIKitKey(symbol: String) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
    config.baseForegroundColor = .label
    config.background.backgroundColor = KeyboardPalette.keyUIColor
    config.background.cornerRadius = 8
    let button = UIButton(configuration: config)
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.2
    button.layer.shadowRadius = 2
    button.layer.shadowOffset = CGSize(width: 0, height: 1)
    button.configurationUpdateHandler = { button in
        guard var config = button.configuration else { return }
        config.background.backgroundColor = KeyboardPalette.keyUIColor.withAlphaComponent(button.isHighlighted ? 0.72 : 1)
        button.configuration = config
        button.transform = button.isHighlighted ? CGAffineTransform(translationX: 0, y: 1) : .identity
    }
    return button
}

private struct GlobeKey: UIViewRepresentable {
    let controller: KeyboardViewController

    func makeUIView(context: Context) -> UIButton {
        let button = makeUIKitKey(symbol: "globe")
        button.accessibilityLabel = "Next keyboard"
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

private struct RepeatingKey: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = makeUIKitKey(symbol: "delete.left")
        button.accessibilityLabel = "Delete"
        button.addTarget(context.coordinator, action: #selector(Coordinator.down), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.up), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        private var timer: Timer?

        init(action: @escaping () -> Void) { self.action = action }

        @objc func down() {
            action()
            timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                self?.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in self?.action() }
            }
        }

        @objc func up() {
            timer?.invalidate()
            timer = nil
        }
    }
}
