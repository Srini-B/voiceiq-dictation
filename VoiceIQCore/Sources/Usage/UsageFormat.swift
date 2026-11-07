import Foundation

/// What a call or a total was billed on, as the Cost and History screens show
/// it: token counts for token-priced models, audio length for models priced
/// by the minute (OpenAI's transcription models).
public enum UsageFormat {
    public static func tokens(_ count: Int) -> String {
        count >= 10_000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    /// "42s", "6m 30s", "1h 05m".
    public static func audio(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", total % 3600 / 60))m"
    }

    /// One call. An audio-priced call booked before its length was stored
    /// has no tokens and no length.
    public static func measure(_ record: UsageRecord) -> String {
        let usage = record.usage
        if !usage.isEmpty { return "in \(tokens(usage.totalIn)) · out \(tokens(usage.totalOut))" }
        if let seconds = record.audioSeconds { return "\(audio(seconds)) of audio" }
        return "billed by audio length"
    }

    /// A total: its tokens, its billed audio, or both.
    public static func measure(_ total: UsageStore.Total) -> String? {
        var parts: [String] = []
        if total.tokensIn > 0 || total.tokensOut > 0 {
            parts.append("in \(tokens(total.tokensIn)) · out \(tokens(total.tokensOut))")
        }
        if total.audioSeconds > 0 { parts.append("\(audio(total.audioSeconds)) of audio") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One row of a dictation's cost breakdown: every call of one stage to one
/// model, summed. Real-time transcription books each request it makes, which
/// listed a row per few seconds of speech.
public struct UsageLine: Identifiable, Sendable {
    /// The calls' tokens, audio and cost added up, under the first call's id.
    public let total: UsageRecord
    public let calls: Int
    public var id: String { total.id }

    /// In the order each stage and model was first called.
    public static func lines(_ records: [UsageRecord]) -> [UsageLine] {
        var order: [String] = []
        var groups: [String: [UsageRecord]] = [:]
        for record in records {
            let key = record.stage + "\u{1F}" + record.model
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record)
        }
        return order.compactMap { groups[$0] }.map { group in
            var total = group[0]
            for record in group.dropFirst() {
                total.textIn += record.textIn; total.audioIn += record.audioIn; total.imageIn += record.imageIn
                total.cachedIn += record.cachedIn; total.textOut += record.textOut; total.audioOut += record.audioOut
                total.thoughtOut += record.thoughtOut
                total.isEstimated = total.isEstimated || record.isEstimated
                total.costUSD = add(total.costUSD, record.costUSD)
                total.audioSeconds = add(total.audioSeconds, record.audioSeconds)
            }
            // A call with no price makes the sum a lower bound.
            if total.costUSD != nil, group.contains(where: { $0.costUSD == nil }) { total.isEstimated = true }
            return UsageLine(total: total, calls: group.count)
        }
    }

    private static func add(_ a: Double?, _ b: Double?) -> Double? {
        a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0)
    }
}
