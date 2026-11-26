import SwiftUI

/// Moves the cursor and edits without letter keys: arrows that repeat while
/// held, word and line steps, the pasteboard, the last dictation again, and undo
/// of the keyboard's own edits. Two rows of six, above the bottom row's space,
/// delete and return; the steps are chevrons, the line ends arrows to a bar, all of one weight.
struct EditPanel: View {
    @ObservedObject var editor: EditController
    let pasteLast: () -> Void
    let pasteLastSymbol: String

    var body: some View {
        HStack(spacing: 6) {
            KeyCap(systemImage: "arrow.left.to.line", label: "Line Start") { editor.moveCursor(.lineStart) }
            KeyCap(systemImage: "chevron.left.2", label: "Previous Word") { editor.moveCursor(.wordLeft) }
            RepeatingKey(symbol: "chevron.left", label: "Left") { editor.moveCursor(.left) }
            RepeatingKey(symbol: "chevron.right", label: "Right") { editor.moveCursor(.right) }
            KeyCap(systemImage: "chevron.right.2", label: "Next Word") { editor.moveCursor(.wordRight) }
            KeyCap(systemImage: "arrow.right.to.line", label: "Line End") { editor.moveCursor(.lineEnd) }
        }
        .frame(maxHeight: .infinity)
        HStack(spacing: 6) {
            KeyCap(systemImage: "doc.on.doc", label: "Copy", enabled: editor.canUsePasteboard) { editor.copySelection(cut: false) }
            KeyCap(systemImage: "scissors", label: "Cut", enabled: editor.canUsePasteboard) { editor.copySelection(cut: true) }
            KeyCap(systemImage: "doc.on.clipboard", label: "Paste", enabled: editor.canUsePasteboard) { editor.paste() }
            KeyCap(systemImage: pasteLastSymbol, label: "Paste last dictation", action: pasteLast)
            KeyCap(systemImage: "arrow.uturn.backward", label: "Undo", enabled: !editor.undoStack.isEmpty) { editor.undo() }
            KeyCap(systemImage: "arrow.uturn.forward", label: "Redo", enabled: !editor.redoStack.isEmpty) { editor.redo() }
        }
        .frame(maxHeight: .infinity)
    }
}
