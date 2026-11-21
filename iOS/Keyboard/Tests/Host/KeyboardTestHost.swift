import SwiftUI

/// Hosts KeyboardTypingTests: its bundle carries Hex's typing model, suggestion
/// filter and emoji index, which the keys read from the main bundle.
@main
struct KeyboardTestHost: App {
    var body: some Scene {
        WindowGroup { Color.clear }
    }
}
