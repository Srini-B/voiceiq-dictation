import SwiftUI
import VoiceIQBridge

/// The recording panel's waveform: one bar per slice of time, newest on the
/// right, each as tall as the microphone level was then. While the text is
/// written the bars stop following the mic and a slow pulse runs across them.
///
/// The level is read from the App Group inside the Canvas at each frame, so
/// it never invalidates the SwiftUI tree.
struct LiveWaveform: View {
    var listening: Bool
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history = History()

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 3
    /// A new bar this often; the bars scroll smoothly in between.
    private static let step: TimeInterval = 0.06

    /// A reference type, so the render loop can update it without state changes.
    private final class History {
        var bars: [CGFloat] = []
        var smoothed: CGFloat = 0
        var lastPush: TimeInterval = 0
        var pushes = 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let pitch = Self.barWidth + Self.gap
        let count = max(1, Int(size.width / pitch) + 1)
        if history.bars.count != count {
            history.bars = Array(repeating: 0, count: max(0, count - history.bars.count)) + history.bars.suffix(count)
        }
        if listening, time - history.lastPush >= Self.step {
            history.lastPush = time
            let target = CGFloat(min(max(SharedStore.shared.level, 0), 1))
            // Fast attack, slow release: syllables jump up and fall back gently.
            history.smoothed += (target - history.smoothed) * (target > history.smoothed ? 0.7 : 0.3)
            // The level saturates for close or loud speech. Spread the top of
            // the range and vary each bar a little, so a loud stretch still
            // reads as a voice instead of a flat block.
            history.pushes += 1
            let variation = 0.78 + 0.22 * CGFloat(abs(sin(Double(history.pushes) * 2.4)))
            history.bars.removeFirst()
            history.bars.append(pow(history.smoothed, 1.4) * variation)
        }
        let progress = listening ? CGFloat((time - history.lastPush) / Self.step) : 0
        let mid = size.height / 2
        for (index, value) in history.bars.enumerated() {
            var level = value
            if !listening {
                // A soft crest moving left to right, about once a second.
                let phase = time * 4 - Double(index) * 0.18
                level = 0.12 + 0.3 * CGFloat(max(0, sin(phase)))
            }
            let height = max(Self.barWidth, size.height * (0.06 + 0.94 * level))
            let x = CGFloat(index) * pitch - progress * pitch
            // Older bars fade toward the left edge.
            let age = CGFloat(index) / CGFloat(max(count - 1, 1))
            let rect = CGRect(x: x, y: mid - height / 2, width: Self.barWidth, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                         with: .color(color.opacity(0.25 + 0.75 * age)))
        }
    }
}
