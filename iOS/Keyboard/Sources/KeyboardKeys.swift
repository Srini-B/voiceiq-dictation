import SwiftUI
import UIKit

enum KeyboardPalette {
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

struct KeyCapStyle: ButtonStyle {
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

struct KeyCap: View {
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
@MainActor
func makeUIKitKey(symbol: String) -> UIButton {
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

struct GlobeKey: UIViewRepresentable {
    /// Weak: the controller owns this view.
    weak var controller: KeyboardViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = makeUIKitKey(symbol: "globe")
        button.accessibilityLabel = "Next keyboard"
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

/// Acts on press, then repeats while held.
struct RepeatingKey: UIViewRepresentable {
    var symbol = "delete.left"
    var label = "Delete"
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = makeUIKitKey(symbol: symbol)
        button.accessibilityLabel = label
        button.addTarget(context.coordinator, action: #selector(Coordinator.down), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.up), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.action = action
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        private var timer: Timer?

        init(action: @escaping () -> Void) { self.action = action }

        @objc func down() {
            action()
            // Scheduled on the main run loop, so they fire on the main actor.
            timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.repeatHeld() }
            }
        }

        private func repeatHeld() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.action() }
            }
        }

        @objc func up() {
            timer?.invalidate()
            timer = nil
        }
    }
}
