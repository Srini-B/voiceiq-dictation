import SwiftUI

/// The 5-bar amplitude-reactive waveform (Gemini Live "condensed into a tiny pill").
/// Both states run the four-color traveling sweep. Live state: bars follow the
/// voice with fast-attack/slow-release smoothing and a calm idle undulation.
/// Processing state: bars freeze into a gentle chase. Writing state (the
/// transcript is in the field as a draft and the writing model rewrites it):
/// one crest sweeps left to right in the processing shimmer's colors, like a
/// pen passing over the line.
struct WaveformView: View {
    /// Read inside the Canvas at each timeline tick, so level changes never
    /// invalidate the SwiftUI view tree.
    var level: LevelSource = .silent
    var processing: Bool
    var writing = false
    /// One colour for every bar, as the Meetings window's level meter; nil keeps the brand colours.
    var tint: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barWidth: CGFloat = 6
    private static let gap: CGFloat = 4
    private static let minHeight: CGFloat = 6
    private static let maxHeight: CGFloat = 38
    /// Per-bar personality: center bar leads, neighbors follow.
    private static let weights: [CGFloat] = [0.6, 0.88, 1.0, 0.8, 0.55]
    private static let phases: [Double] = [0.0, 0.9, 1.7, 2.6, 3.4]

    /// Fast-attack / slow-release smoothing (spec §1.4) — reference type so the
    /// Canvas render loop can mutate it without touching SwiftUI state.
    private final class Smoother {
        var values: [CGFloat] = [0, 0, 0, 0, 0]

        func step(bar: Int, toward target: CGFloat) -> CGFloat {
            let current = values[bar]
            let coefficient: CGFloat = target > current ? 0.38 : 0.09
            let next = current + (target - current) * coefficient
            values[bar] = next
            return next
        }
    }

    @State private var smoother = Smoother()

    var body: some View {
        if reduceMotion {
            staticBars
        } else {
            // Cap the redraw schedule: the fastest visual term is the 2.4–4.6Hz
            // per-bar shimmer while listening and a ~0.7Hz chase while
            // processing, so full display rate buys nothing but main-thread
            // CoreAnimation commits (~1.4ms each, 60×/s for the whole session).
            TimelineView(.animation(minimumInterval: processing ? 1.0 / 12.0 : 1.0 / 24.0)) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    drawBars(context: &context, size: size, time: t)
                }
            }
            .frame(width: totalWidth, height: Self.maxHeight)
        }
    }

    private var totalWidth: CGFloat {
        Self.barWidth * 5 + Self.gap * 4
    }

    private func drawBars(context: inout GraphicsContext, size: CGSize, time: Double) {
        let sweep = (time.truncatingRemainder(dividingBy: 1.2)) / 1.2
        for index in 0..<5 {
            let height = barHeight(index: index, time: time)
            let x = CGFloat(index) * (Self.barWidth + Self.gap)
            let rect = CGRect(
                x: x,
                y: (size.height - height) / 2,
                width: Self.barWidth,
                height: height
            )
            let path = Path(roundedRect: rect, cornerRadius: Self.barWidth / 2)
            let hue = (Double(index) / 5.0 + sweep).truncatingRemainder(dividingBy: 1.0)
            context.fill(path, with: .color(tint ?? (writing ? shimmerColor(at: hue) : quadColor(at: hue))))
        }
    }

    private func barHeight(index: Int, time: Double) -> CGFloat {
        if processing && writing {
            // One crest travels across the bars every 0.9 s, with a beat of
            // rest before the next.
            let crest = (time / 0.9).truncatingRemainder(dividingBy: 1.0) * 7 - 1
            let distance = Double(index) - crest
            return 8 + 26 * CGFloat(exp(-distance * distance / 0.9))
        }
        if processing {
            // Gentle 4-phase chase between 10 and 22pt, staggered — "thinking".
            let phase = sin(time * 2 * .pi / 1.4 + Self.phases[index])
            return 16 + phase * 6
        }
        // Target = level-reactive rise with strong per-bar speech shimmer; the
        // smoother gives it fast attack (bars leap with your voice) and slow
        // release (they fall like a VU meter, not a strobe).
        let shimmer = sin(time * 2 * .pi * (2.4 + Double(index) * 0.55) + Self.phases[index] * 2)
        let target = CGFloat(level.value) * Self.weights[index] * (1 + CGFloat(shimmer) * 0.35)
        let smoothed = smoother.step(bar: index, toward: min(1, max(0, target)))
        // Idle breathing keeps the pill alive between phrases.
        let idle = sin(time * 2 * .pi * 0.8 + Self.phases[index]) * 2
        let height = Self.minHeight + idle + smoothed * (Self.maxHeight - Self.minHeight)
        return min(Self.maxHeight, max(Self.minHeight, height))
    }

    private func shimmerColor(at position: Double) -> Color {
        let colors = VoiceIQUI.Colors.aiShimmer
        return colors[Int(position * Double(colors.count)) % colors.count]
    }

    private func quadColor(at position: Double) -> Color {
        // Blue → Red → Yellow → Green loop.
        let colors = VoiceIQUI.Colors.brandQuad
        let scaled = position * Double(colors.count)
        return colors[Int(scaled) % colors.count]
    }

    /// Reduce Motion: static 5-bar level meter, opacity-only response.
    private var staticBars: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { _ in
            HStack(spacing: Self.gap) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: Self.barWidth / 2)
                        .fill(tint ?? VoiceIQUI.Colors.brandQuad[index % 4])
                        .frame(
                            width: Self.barWidth,
                            height: Self.minHeight + Self.weights[index] * 14
                        )
                        .opacity(processing ? 0.8 : 0.4 + Double(level.value) * 0.6)
                }
            }
        }
        .frame(height: Self.maxHeight)
    }
}
