import Combine
import SwiftUI
import VoiceIQBridge

/// The recording panel's waveform: one bar per slice of time, newest on the
/// right, each as tall as the microphone level was then. While the text is
/// written the bars stop following the mic and a slow pulse runs across them.
///
/// Plain shapes on a timer, not a `Canvas` in a `TimelineView`: on an iPhone
/// (0.6.22) that version drew nothing in the keyboard, though it drew in the
/// Simulator. The keyboard's other live views already update this way.
struct LiveWaveform: View {
    var listening: Bool
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bars: [CGFloat] = []
    @State private var smoothed: CGFloat = 0
    @State private var ticks = 0

    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 3
    /// A new bar this often.
    private static let step: TimeInterval = 0.06
    private let clock = Timer.publish(every: step, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, Int(geometry.size.width / (Self.barWidth + Self.gap)))
            HStack(alignment: .center, spacing: Self.gap) {
                ForEach(0..<count, id: \.self) { index in
                    let level = level(at: index, count: count)
                    Capsule()
                        .fill(color.opacity(0.25 + 0.75 * CGFloat(index) / CGFloat(max(count - 1, 1))))
                        .frame(width: Self.barWidth,
                               height: max(Self.barWidth, geometry.size.height * (0.06 + 0.94 * level)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            .onReceive(clock) { _ in advance(count: count) }
        }
        .accessibilityHidden(true)
    }

    private func level(at index: Int, count: Int) -> CGFloat {
        guard listening else {
            // A soft crest moving left to right, about once a second.
            let phase = Double(ticks) * Self.step * 4 - Double(index) * 0.18
            return 0.12 + 0.3 * CGFloat(max(0, sin(phase)))
        }
        let offset = index - (count - bars.count)
        return offset >= 0 ? bars[offset] : 0
    }

    private func advance(count: Int) {
        guard !reduceMotion else { return }
        ticks += 1
        guard listening else { return }
        let target = CGFloat(min(max(SharedStore.shared.level, 0), 1))
        // Fast attack, slow release: syllables jump up and fall back gently.
        smoothed += (target - smoothed) * (target > smoothed ? 0.7 : 0.3)
        // The level saturates for close or loud speech. Spread the top of the
        // range and vary each bar a little, so a loud stretch still reads as
        // a voice instead of a flat block.
        let variation = 0.78 + 0.22 * CGFloat(abs(sin(Double(ticks) * 2.4)))
        bars.append(pow(smoothed, 1.4) * variation)
        if bars.count > count { bars.removeFirst(bars.count - count) }
    }
}
