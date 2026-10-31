import SwiftUI

/// Moves the cursor and edits without the keys: arrows that repeat while
/// held, word and line steps, the pasteboard, and undo of the keyboard's own
/// typing. Keyboards cannot select text or reach the app's own undo.
struct EditPanel: View {
    @ObservedObject var typing: TypingController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                key("Line Start", "arrow.left.to.line") { typing.moveCursor(.lineStart) }
                key("Previous Word", "chevron.backward.2") { typing.moveCursor(.wordLeft) }
                key("Next Word", "chevron.forward.2") { typing.moveCursor(.wordRight) }
                key("Line End", "arrow.right.to.line") { typing.moveCursor(.lineEnd) }
            }
            HStack(spacing: 8) {
                RepeatKey(label: "Left", systemImage: "arrowtriangle.left.fill", theme: typing.theme) { typing.moveCursor(.left) }
                RepeatKey(label: "Right", systemImage: "arrowtriangle.right.fill", theme: typing.theme) { typing.moveCursor(.right) }
            }
            HStack(spacing: 8) {
                key("Copy", "doc.on.doc", enabled: typing.canUsePasteboard) { typing.copySelection(cut: false) }
                key("Cut", "scissors", enabled: typing.canUsePasteboard) { typing.copySelection(cut: true) }
                key("Paste", "doc.on.clipboard", enabled: typing.canUsePasteboard) { typing.paste() }
                key("Undo", "arrow.uturn.backward", enabled: !typing.undoStack.isEmpty) { typing.undo() }
                key("Redo", "arrow.uturn.forward", enabled: !typing.redoStack.isEmpty) { typing.redo() }
            }
            HStack(spacing: 8) {
                Button("ABC") { typing.showsEdit = false }
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 64, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(typing.theme.function.top)))
                Spacer()
                RepeatKey(label: "Delete", systemImage: "delete.left", theme: typing.theme) {
                    typing.keyTapped(KeySpec(action: .delete, label: "delete"), text: nil)
                }
                .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(8)
    }

    private func key(_ label: String, _ systemImage: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(typing.theme.character.top)))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// Acts on press, then repeats while held, like the delete key.
private struct RepeatKey: View {
    let label: String
    let systemImage: String
    let theme: KeyTheme
    let action: () -> Void
    @State private var timer: Timer?
    /// Resets when the touch ends or is cancelled, unlike `onEnded`.
    @GestureState private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(pressed ? theme.function.top : theme.character.top)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, pressed, _ in pressed = true })
            .onChange(of: pressed) { _, pressed in pressed ? start() : stop() }
            .onDisappear(perform: stop)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func start() {
        action()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                    MainActor.assumeIsolated { action() }
                }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
