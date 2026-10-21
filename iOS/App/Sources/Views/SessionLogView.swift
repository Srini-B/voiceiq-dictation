import SwiftUI
import UIKit
import VoiceIQBridge

/// The session and background-start events from `SessionDiagnostics`.
struct SessionLogView: View {
    @State private var text = SessionLogView.combined()
    @State private var copied = false

    /// The app's events, then the keyboard's.
    static func combined() -> String {
        let app = SessionDiagnostics.read()
        let keyboard = SharedStore.shared.keyboardLog.joined(separator: "\n")
        guard !keyboard.isEmpty else { return app }
        return app + (app.isEmpty ? "" : "\n\n") + "Keyboard\n" + keyboard
    }

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No events yet." : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.page)
        }
        .themedBackground()
        .navigationTitle("Session log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = text
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") {
                    SessionDiagnostics.clear()
                    SharedStore.shared.clearKeyboardLog()
                    text = ""
                }
            }
        }
        .onAppear { text = SessionLogView.combined() }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }
}
