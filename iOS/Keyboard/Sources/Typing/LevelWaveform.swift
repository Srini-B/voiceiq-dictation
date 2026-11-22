import Combine
import SwiftUI
import VoiceIQBridge

/// The recording strip's waveform: one bar per level the dictation recorded,
/// newest on the right, each as tall as the voice was loud then. It reads the
/// app's `LevelBars`, so the keyboard shows the dictation so far however
/// often it was hidden.
///
/// One shape on a timer, not a `Canvas` in a `TimelineView`: on an iPhone
/// (0.6.22) that version drew nothing in the keyboard, though it drew in the
/// Simulator. The timer goes with the view when the recording ends.
struct LevelWaveform: View {
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels: [Float] = []

    /// Redrawn this often; the app adds a level about as often.
    private let clock = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        BarsShape(levels: levels)
            .fill(color)
            .onAppear(perform: advance)
            .onReceive(clock) { _ in advance() }
            .accessibilityHidden(true)
    }

    private func advance() {
        let latest = LevelWaveformSource.levels()
        // Reduce Motion keeps the bars still at the dictation's latest height.
        let shown = reduceMotion ? Array(repeating: latest.last ?? 0, count: LevelBars.capacity) : latest
        if shown != levels { levels = shown }
    }
}

/// Rounded bars centred on the middle line, as many as fit, newest at the
/// right edge. Silence keeps a short bar; the loudest speech fills the height.
private struct BarsShape: Shape {
    var levels: [Float]

    static let width: CGFloat = 3
    static let gap: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let count = max(1, Int((rect.width + Self.gap) / (Self.width + Self.gap)))
        let shown = Array(levels.suffix(count))
        let padded = Array(repeating: Float(0), count: count - shown.count) + shown
        var path = Path()
        for (index, level) in padded.enumerated() {
            let height = max(Self.width, rect.height * (0.12 + 0.88 * CGFloat(min(max(level, 0), 1))))
            let x = rect.maxX - CGFloat(count - index) * (Self.width + Self.gap) + Self.gap
            path.addRoundedRect(in: CGRect(x: x, y: rect.midY - height / 2, width: Self.width, height: height),
                                cornerSize: CGSize(width: Self.width / 2, height: Self.width / 2))
        }
        return path
    }
}

/// Where the waveform reads the dictation's levels: the app's, through the App
/// Group, unless the keyboard records the dictation itself.
enum LevelWaveformSource {
    @MainActor static var levels: () -> [Float] = { SharedStore.shared.levelBars }
}
