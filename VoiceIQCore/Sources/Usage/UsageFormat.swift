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
