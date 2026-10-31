import CoreGraphics
import Foundation

/// Slide to type with FUTO Swipe (see THIRD_PARTY_NOTICES.md): a neural
/// encoder reads the finger's path, a QWERTY decoder and a context model
/// rank the words, and a beam search keeps them to the dictionary and the
/// user's own words. Its 21 MB of models load on a background queue, which
/// also runs each recognition, so a slide never waits on the main thread.
final class SwipeRecognizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.blue.voiceiq.keyboard.swipe", qos: .userInitiated)
    private let directory = Bundle.main.resourceURL!.appendingPathComponent("swipe").path
    /// Touched only on `queue`.
    private var engine: FUTOSwipe?
    private var userWords: [String] = []
    /// The letter keys' bounds: a gesture is measured in fractions of it.
    /// Main thread only.
    private var frame: CGRect?

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    private static let qwertyRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    func update(_ geometry: KeyGeometry) {
        let centers = Self.alphabet.compactMap { geometry.centers[$0] }
        guard centers.count == 26 else { frame = nil; return }
        let xs = centers.map(\.x), ys = centers.map(\.y)
        let frame = CGRect(x: xs.min()! - geometry.keyWidth / 2, y: ys.min()! - geometry.keyHeight / 2,
                           width: xs.max()! - xs.min()! + geometry.keyWidth,
                           height: ys.max()! - ys.min()! + geometry.keyHeight)
        self.frame = frame
        let normalized = centers.map { Self.normalize($0, in: frame) }
        let layoutXs = normalized.map { NSNumber(value: Float($0.x)) }
        let layoutYs = normalized.map { NSNumber(value: Float($0.y)) }
        let decoder = Self.rows(geometry) == Self.qwertyRows
        queue.async { [self] in
            if let engine {
                engine.setLayoutXs(layoutXs, ys: layoutYs, decoder: decoder)
            } else {
                engine = FUTOSwipe(directory: directory, xs: layoutXs, ys: layoutYs, decoder: decoder)
                if !userWords.isEmpty { engine?.setUserWords(userWords) }
            }
        }
    }

    /// Letters a to z only; others cannot be slid to.
    func setUserWords(_ keys: [String]) {
        let words = keys.filter { !$0.isEmpty && $0.allSatisfy { ("a"..."z").contains($0) } }.sorted()
        queue.async { [self] in
            guard words != userWords else { return }
            userWords = words
            engine?.setUserWords(words)
        }
    }

    /// Calls `done` on the main thread with the best words first, or none.
    /// - Parameters:
    ///   - times: seconds, one per point.
    ///   - context: the words before the cursor, oldest first.
    @MainActor
    func recognize(_ points: [CGPoint], times: [TimeInterval], context: [String],
                   done: @escaping @MainActor ([String]) -> Void) {
        guard let frame, points.count >= 2, points.count == times.count else { return done([]) }
        let normalized = points.map { Self.normalize($0, in: frame) }
        let xs = normalized.map { Float($0.x) }, ys = normalized.map { Float($0.y) }
        let ts = times.map { Float(($0 - times[0]) * 1000) }
        queue.async { [self] in
            let words = engine?.recognizeX(xs, y: ys, t: ts, count: xs.count, context: context) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { done(words) } }
        }
    }

    private static func normalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    /// The letters row by row, left to right.
    private static func rows(_ geometry: KeyGeometry) -> [String] {
        let byRow = Dictionary(grouping: geometry.centers) { Int($0.value.y.rounded()) }
        return byRow.keys.sorted().map { row in
            String(byRow[row]!.sorted { $0.value.x < $1.value.x }.map(\.key))
        }
    }
}
