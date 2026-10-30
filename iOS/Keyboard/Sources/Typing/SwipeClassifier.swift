import CoreGraphics
import Foundation

/// Slide to type: finds the words whose ideal path through the keys looks
/// most like the finger's path.
///
/// Ported from FlorisBoard's `StatisticalGlideTypingClassifier` (Apache 2.0,
/// itself from AnySoftKeyboard; see THIRD_PARTY_NOTICES.md). Each candidate's
/// ideal path is compared with the gesture twice: by shape, after scaling both
/// to a unit box, and by location, in key widths. Both distances become
/// Gaussian likelihoods and are multiplied by how likely the word is here.
/// Candidates are first pruned to words that start and end on the keys
/// nearest the gesture's ends and whose ideal path is about as long.
struct SwipeClassifier: Sendable {
    private static let samples = 64
    private static let shapeSD = 22.08 * Double(samples) / 200
    private static let locationSD = 0.5109
    private static let lengthTolerance = 8.42
    /// Only this many of the most common words are slid to; rarer ones are typed.
    private static let vocabularySize = 40_000

    let geometry: KeyGeometry
    /// Word IDs by first and last letter.
    private let buckets: [String: [Lexicon.WordID]]

    init(lexicon: Lexicon, geometry: KeyGeometry) {
        self.geometry = geometry
        var ranked: [(Lexicon.WordID, Double)] = []
        ranked.reserveCapacity(lexicon.count)
        for id in 0..<lexicon.count where !lexicon.flags(id).contains(.noSuggest) {
            ranked.append((id, lexicon.logProbability(id)))
        }
        ranked.sort { $0.1 > $1.1 }
        var buckets: [String: [Lexicon.WordID]] = [:]
        for (id, _) in ranked.prefix(Self.vocabularySize) {
            let key = lexicon.key(id)
            guard key.count >= 2, let first = key.first, let last = key.last,
                  geometry.centers[first] != nil, geometry.centers[last] != nil else { continue }
            buckets[String([first, last]), default: []].append(id)
        }
        self.buckets = buckets
    }

    /// Best words for the gesture, most likely first.
    /// - Parameter prior: ln probability of a word here (context and frequency).
    func classify(_ points: [CGPoint], lexicon: Lexicon, extra: [String] = [],
                  prior: (Lexicon.WordID) -> Double, limit: Int = 4) -> [String] {
        guard points.count >= 2 else { return [] }
        let user = resample(points)
        let userShape = normalized(user)
        let userLength = length(points)
        let starts = nearestLetters(to: points[0], count: 2)
        let ends = nearestLetters(to: points[points.count - 1], count: 2)
        let tolerance = Self.lengthTolerance * Double(min(geometry.keyWidth, geometry.keyHeight))

        var scored: [(String, Double)] = []
        func score(_ key: String, display: String, logPrior: Double) {
            guard let ideal = idealPath(for: key) else { return }
            guard abs(length(ideal) - userLength) < tolerance else { return }
            let path = resample(ideal)
            let shape = zip(normalized(path), userShape).reduce(0.0) { $0 + Double(hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y)) }
            let location = zip(path, user).reduce(0.0) {
                $0 + Double(abs($1.0.x - $1.1.x) / geometry.keyWidth + abs($1.0.y - $1.1.y) / geometry.keyHeight)
            } / Double(Self.samples) / 2
            let logLikelihood = -0.5 * pow(shape / Self.shapeSD, 2) - 0.5 * pow(location / Self.locationSD, 2)
            scored.append((display, logLikelihood + logPrior))
        }
        for first in starts {
            for last in ends {
                for id in buckets[String([first, last])] ?? [] {
                    score(lexicon.key(id), display: lexicon.display(id), logPrior: prior(id))
                }
            }
        }
        for word in extra {
            let key = TypingEngine.key(of: word)
            if let first = key.first, let last = key.last, starts.contains(first), ends.contains(last) {
                score(key, display: word, logPrior: -11)
            }
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.lowercased()).inserted }.prefix(limit).map { $0 }
    }

    // MARK: - Paths

    /// Key centres in order; a doubled letter adds a small loop so "pool" and
    /// "pol" differ.
    func idealPath(for key: String) -> [CGPoint]? {
        var path: [CGPoint] = []
        var previous: Character?
        for letter in key {
            guard let center = geometry.centers[letter] else { return nil }
            if letter == previous {
                let dx = geometry.keyWidth / 4, dy = geometry.keyHeight / 4
                path += [CGPoint(x: center.x + dx, y: center.y + dy), CGPoint(x: center.x + dx, y: center.y - dy),
                         CGPoint(x: center.x - dx, y: center.y - dy), CGPoint(x: center.x - dx, y: center.y + dy)]
            }
            path.append(center)
            previous = letter
        }
        return path
    }

    private func nearestLetters(to point: CGPoint, count: Int) -> [Character] {
        geometry.centers.sorted {
            hypot($0.value.x - point.x, $0.value.y - point.y) < hypot($1.value.x - point.x, $1.value.y - point.y)
        }.prefix(count).map(\.key)
    }

    private func length(_ points: [CGPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + Double(hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)) }
    }

    /// `samples` points evenly spaced along the path.
    private func resample(_ points: [CGPoint]) -> [CGPoint] {
        let total = length(points)
        guard total > 0 else { return Array(repeating: points[0], count: Self.samples) }
        let step = total / Double(Self.samples - 1)
        var out = [points[0]]
        var carried = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = Double(hypot(b.x - a.x, b.y - a.y))
            guard segment > 0 else { continue }
            var at = step - carried
            while at <= segment, out.count < Self.samples {
                let t = CGFloat(at / segment)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                at += step
            }
            carried = segment - (at - step)
        }
        while out.count < Self.samples { out.append(points[points.count - 1]) }
        return out
    }

    /// Scaled so the longer side of its bounding box is 1, centred on 0.
    private func normalized(_ points: [CGPoint]) -> [CGPoint] {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let side = max(maxX - minX, maxY - minY, 0.00001)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        return points.map { CGPoint(x: ($0.x - cx) / side, y: ($0.y - cy) / side) }
    }
}
