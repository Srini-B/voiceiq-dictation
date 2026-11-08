import Combine
import SwiftUI
import VoiceIQBridge

/// The recording strip's glow: a fill that rises from the bottom edge as
/// loud as the voice was, brightest near the bottom, fading upward and
/// feathered over its last few points into the keys below. Its top
/// edge follows the app's `LevelBars`, newest on the right, so the keyboard
/// shows the dictation so far however often it was hidden.
///
/// A plain shape on a timer, not a `Canvas` in a `TimelineView`: on an iPhone
/// (0.6.22) that version drew nothing in the keyboard, though it drew in the
/// Simulator. The keyboard's other live views already update this way.
struct LevelGlow: View {
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels: [Float] = []

    /// One level per this many points across the strip.
    private static let spacing: CGFloat = 8
    /// Redrawn this often; the app adds a level about as often.
    private let clock = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let count = max(2, Int(geometry.size.width / Self.spacing) + 1)
            GlowShape(levels: Array(levels.suffix(count)), count: count)
                .fill(LinearGradient(colors: [color.opacity(0.6), color.opacity(0)],
                                     startPoint: .bottom, endPoint: .top))
                .blur(radius: 2)
                // Soft on every side, so no edge reads as a line: a bright
                // bottom edge looked like a divider above the keys, with the
                // buttons sitting on it.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                // Only the last few points feather out, so the glow still
                // rises from the bottom rather than floating as a band.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.84),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .onAppear(perform: advance)
        .onReceive(clock) { _ in advance() }
        .accessibilityHidden(true)
    }

    private func advance() {
        let latest = SharedStore.shared.levelBars
        // Reduce Motion keeps the glow still at the dictation's latest height.
        let shown = reduceMotion ? Array(repeating: latest.last ?? 0, count: LevelBars.capacity) : latest
        if shown != levels { levels = shown }
    }
}

/// The area under a smooth curve through the levels, the newest at the right
/// edge. Positions without a level yet sit at the floor.
private struct GlowShape: Shape {
    var levels: [Float]
    var count: Int

    func path(in rect: CGRect) -> Path {
        let padded = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels
        let step = rect.width / CGFloat(max(count - 1, 1))
        let points = padded.enumerated().map { index, level in
            CGPoint(x: CGFloat(index) * step,
                    // Silence keeps a low glow; the loudest speech reaches
                    // three quarters of the way up, so it reads as rising.
                    y: rect.maxY - rect.height * (0.12 + 0.63 * CGFloat(min(max(level, 0), 1))))
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: points[0])
        // Midpoint quadratics: the curve passes between the levels, never
        // overshooting them.
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2),
                              control: previous)
        }
        path.addLine(to: points[points.count - 1])
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
