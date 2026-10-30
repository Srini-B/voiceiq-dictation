import Foundation

/// The English word list and word pairs from `lexicon.bin`, read in place.
///
/// The file is memory-mapped: its pages are clean and backed by the bundle,
/// so the 3.5 MB do not count against the keyboard's memory limit the way a
/// parsed dictionary would. Layout: `scripts/generate-keyboard-data.py`.
struct Lexicon: @unchecked Sendable {
    typealias WordID = Int

    struct Flags: OptionSet {
        let rawValue: UInt8
        /// Valid, but never offered: offensive words and stray letters.
        static let noSuggest = Flags(rawValue: 1)
        /// A contraction that wins over its apostrophe-less key ("dont").
        static let preferred = Flags(rawValue: 2)
    }

    private let data: Data
    let count: Int
    private let pairCount: Int
    private let lnMin, lnMax, lnTotal, pairLnMin, pairLnMax: Double
    private let wordsAt = 40
    private let pairsAt: Int
    private let scoresAt: Int
    private let blobAt: Int

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 40,
              data.prefix(4) == Data("VQLX".utf8) else { return nil }
        self.data = data
        func u32(_ at: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }) }
        func f32(_ at: Int) -> Double { Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: Float32.self) }) }
        guard u32(4) == 1 else { return nil }
        count = u32(8)
        pairCount = u32(12)
        lnMin = f32(20); lnMax = f32(24); lnTotal = f32(28); pairLnMin = f32(32); pairLnMax = f32(36)
        pairsAt = wordsAt + count * 8
        scoresAt = pairsAt + pairCount * 8
        blobAt = scoresAt + pairCount
        guard blobAt + u32(16) == data.count else { return nil }
    }

    // MARK: - Words

    private func record(_ id: WordID) -> (offset: Int, keyLength: Int, displayLength: Int, frequency: UInt8, flags: UInt8) {
        data.withUnsafeBytes { raw in
            let at = wordsAt + id * 8
            return (Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)),
                    Int(raw[at + 4]), Int(raw[at + 5]), raw[at + 6], raw[at + 7])
        }
    }

    func key(_ id: WordID) -> String {
        let r = record(id)
        return string(at: blobAt + r.offset, length: r.keyLength)
    }

    /// The word as written: "I'm", "iPhone", "don't".
    func display(_ id: WordID) -> String {
        let r = record(id)
        return r.displayLength == 0
            ? string(at: blobAt + r.offset, length: r.keyLength)
            : string(at: blobAt + r.offset + r.keyLength, length: r.displayLength)
    }

    func flags(_ id: WordID) -> Flags { Flags(rawValue: record(id).flags) }

    /// Natural log of the word's share of all words.
    func logProbability(_ id: WordID) -> Double {
        lnMin + Double(record(id).frequency) / 255 * (lnMax - lnMin) - lnTotal
    }

    private func string(at offset: Int, length: Int) -> String {
        String(decoding: data[offset..<offset + length], as: UTF8.self)
    }

    /// -1, 0 or 1 comparing the key of `id` with `probe`, looking only at the
    /// first `probe.count` bytes when `prefix` is set.
    private func compare(_ id: WordID, _ probe: [UInt8], prefix: Bool) -> Int {
        let r = record(id)
        return data.withUnsafeBytes { raw in
            let start = blobAt + r.offset
            let length = prefix ? min(r.keyLength, probe.count) : r.keyLength
            for i in 0..<min(length, probe.count) {
                let a = raw[start + i], b = probe[i]
                if a != b { return a < b ? -1 : 1 }
            }
            if prefix { return r.keyLength < probe.count ? -1 : 0 }
            return length == probe.count ? 0 : (length < probe.count ? -1 : 1)
        }
    }

    private func lowerBound(_ probe: [UInt8], prefix: Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, probe, prefix: prefix) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Words whose key starts with `prefix`, in key order.
    func range(prefix: String) -> Range<WordID> {
        let probe = Array(prefix.utf8)
        let start = lowerBound(probe, prefix: true)
        var low = start, high = count
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, probe, prefix: true) <= 0 { low = mid + 1 } else { high = mid }
        }
        return start..<low
    }

    /// Words with exactly this key; "cant" gives "cant" and "can't".
    func words(key: String) -> [WordID] {
        let probe = Array(key.utf8)
        var id = lowerBound(probe, prefix: false), out: [WordID] = []
        while id < count, compare(id, probe, prefix: false) == 0 {
            out.append(id)
            id += 1
        }
        return out
    }

    // MARK: - Pairs

    /// Words seen after `id`, most likely first, with ln P(next | id).
    func followers(of id: WordID, limit: Int) -> [(WordID, Double)] {
        var out: [(WordID, Double)] = []
        var index = pairStart(id)
        while index < pairCount, pairFirst(index) == id, out.count < limit {
            out.append((pairSecond(index), pairLogCount(index) - logCount(id)))
            index += 1
        }
        return out
    }

    private func pairStart(_ id: WordID) -> Int {
        var low = 0, high = pairCount
        while low < high {
            let mid = (low + high) / 2
            if pairFirst(mid) < id { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func logCount(_ id: WordID) -> Double { logProbability(id) + lnTotal }
    private func pairFirst(_ i: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pairsAt + i * 8, as: UInt32.self) }) }
    private func pairSecond(_ i: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pairsAt + i * 8 + 4, as: UInt32.self) }) }
    private func pairLogCount(_ i: Int) -> Double {
        pairLnMin + Double(data[scoresAt + i]) / 255 * (pairLnMax - pairLnMin)
    }
}
