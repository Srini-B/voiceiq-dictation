import SwiftUI

/// Moves the cursor and edits without letter keys: arrows that repeat while
/// held, word and line steps, the pasteboard, and undo of the keyboard's own
/// edits. Two rows, above the bottom row's space, delete and return.
struct EditPanel: View {
    @ObservedObject var editor: EditController
    let rowHeight: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                KeyCap(systemImage: "arrow.left.to.line", label: "Line Start") { editor.moveCursor(.lineStart) }
                KeyCap(systemImage: "chevron.backward.2", label: "Previous Word") { editor.moveCursor(.wordLeft) }
                RepeatingKey(symbol: "arrowtriangle.left.fill", label: "Left") { editor.moveCursor(.left) }
                RepeatingKey(symbol: "arrowtriangle.right.fill", label: "Right") { editor.moveCursor(.right) }
                KeyCap(systemImage: "chevron.forward.2", label: "Next Word") { editor.moveCursor(.wordRight) }
                KeyCap(systemImage: "arrow.right.to.line", label: "Line End") { editor.moveCursor(.lineEnd) }
            }
            .frame(height: rowHeight)
            HStack(spacing: 6) {
                KeyCap(systemImage: "doc.on.doc", label: "Copy", enabled: editor.canUsePasteboard) { editor.copySelection(cut: false) }
                KeyCap(systemImage: "scissors", label: "Cut", enabled: editor.canUsePasteboard) { editor.copySelection(cut: true) }
                KeyCap(systemImage: "doc.on.clipboard", label: "Paste", enabled: editor.canUsePasteboard) { editor.paste() }
                KeyCap(systemImage: "arrow.uturn.backward", label: "Undo", enabled: !editor.undoStack.isEmpty) { editor.undo() }
                KeyCap(systemImage: "arrow.uturn.forward", label: "Redo", enabled: !editor.redoStack.isEmpty) { editor.redo() }
            }
            .frame(height: rowHeight)
        }
    }
}
