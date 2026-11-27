import Foundation

/// A stretch of a meeting by time into it, written the way the transcript
/// shows times: "mm:ss" or "h:mm:ss". Either end may be open. Agents use it
/// to read part of a long meeting.
public struct TranscriptRange: Equatable, Sendable {
    /// Seconds from the start of the recording.
    public var from: Double?
    public var to: Double?

    public init(from: Double? = nil, to: Double? = nil) {
        self.from = from
        self.to = to
    }

    public struct Invalid: Error, Equatable {
        public var message: String
    }

    static let forms = "a time into the meeting as mm:ss or h:mm:ss, such as 12:30 or 1:05:00"

    /// Nil when neither end is given. Blank ends are open.
    public static func parse(from: String?, to: String?) -> Result<TranscriptRange?, Invalid> {
        var range = TranscriptRange()
        for (name, raw, end) in [("from", from, \TranscriptRange.from), ("to", to, \TranscriptRange.to)] {
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let value = Self.seconds(raw) else {
                return .failure(Invalid(message: "\(name) takes \(forms); \"\(raw)\" is not one."))
            }
            range[keyPath: end] = value
        }
        if range.from == nil, range.to == nil { return .success(nil) }
        if let to = range.to, (range.from ?? 0) >= to {
            return .failure(Invalid(message: "from (\(MeetingNotesPrompt.clock(range.from ?? 0))) must be earlier than to (\(MeetingNotesPrompt.clock(to)))."))
        }
        return .success(range)
    }

    /// "mm:ss" (any number of minutes) or "h:mm:ss"; after a colon, always two digits.
    static func seconds(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, values.last! < 60, parts.count == 2 || values[1] < 60 else { return nil }
        return Double(values.reduce(0) { $0 * 60 + $1 })
    }

    /// A turn that overlaps the range is kept whole. A turn with no time
    /// cannot be placed, so a range leaves it out.
    public func includes(_ segment: TranscriptSegment) -> Bool {
        guard let start = segment.start else { return false }
        let end = max(segment.end ?? start, start)
        return (from.map { end > $0 || start >= $0 } ?? true) && (to.map { start < $0 } ?? true)
    }

    /// "12:00 to 20:00", "from 12:00 on" or "up to 20:00".
    public var label: String {
        switch (from, to) {
        case let (from?, to?): "\(MeetingNotesPrompt.clock(from)) to \(MeetingNotesPrompt.clock(to))"
        case let (from?, nil): "from \(MeetingNotesPrompt.clock(from)) on"
        case let (nil, to?): "up to \(MeetingNotesPrompt.clock(to))"
        case (nil, nil): "all of it"
        }
    }
}
