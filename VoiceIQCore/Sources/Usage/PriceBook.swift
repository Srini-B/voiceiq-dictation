import Foundation

/// Paid-tier Standard prices from ai.google.dev/gemini-api/docs/pricing,
/// USD per one million tokens, copied 2026-09-26. A free-tier key is billed
/// nothing; the app cannot tell which tier a key is on, so it always shows
/// the paid-tier figure and says so on the Cost pane.
///
/// Models are matched by prefix, longest first, so a dated suffix
/// (`-preview-09-2026`) still resolves.
public struct ModelPrice: Equatable, Sendable {
    public var textIn: Double
    public var audioIn: Double
    public var imageIn: Double
    public var cachedIn: Double
    public var textOut: Double
    public var audioOut: Double

    public init(textIn: Double, audioIn: Double? = nil, imageIn: Double? = nil,
                cachedIn: Double = 0, textOut: Double, audioOut: Double? = nil) {
        self.textIn = textIn
        self.audioIn = audioIn ?? textIn
        self.imageIn = imageIn ?? textIn
        self.cachedIn = cachedIn
        self.textOut = textOut
        self.audioOut = audioOut ?? textOut
    }

    public func cost(_ usage: TokenUsage) -> Double {
        let perMillion = Double(usage.textIn) * textIn
            + Double(usage.audioIn) * audioIn
            + Double(usage.imageIn) * imageIn
            + Double(usage.cachedIn) * cachedIn
            + Double(usage.textOut + usage.thoughtOut) * textOut
            + Double(usage.audioOut) * audioOut
        return perMillion / 1_000_000
    }
}

public enum PriceBook {
    /// Gemini 3.8 Flash doubles on 2027-01-01 per the pricing page.
    static let flash38Increase = Calendar(identifier: .gregorian)
        .date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2027, month: 1, day: 1))!

    static func prices(at date: Date) -> [(prefix: String, price: ModelPrice)] {
        let late = date >= flash38Increase
        return [
            ("gemini-3.8-flash", late
                ? ModelPrice(textIn: 1.50, cachedIn: 0.15, textOut: 7.50)
                : ModelPrice(textIn: 0.75, cachedIn: 0.075, textOut: 3.75)),
            ("gemini-3.5-transcribe", ModelPrice(textIn: 2.00, audioIn: 2.00, textOut: 12.00)),
            ("gemini-3.1-flash-lite", ModelPrice(textIn: 0.25, audioIn: 0.50, cachedIn: 0.025, textOut: 1.50)),
            ("gemini-3-flash", ModelPrice(textIn: 0.50, audioIn: 1.00, cachedIn: 0.05, textOut: 3.00)),
            ("gemini-2.5-flash-lite", ModelPrice(textIn: 0.10, audioIn: 0.30, textOut: 0.40)),
            ("gemini-2.5-flash", ModelPrice(textIn: 0.30, audioIn: 1.00, cachedIn: 0.03, textOut: 2.50)),
            // developers.openai.com/api/docs/pricing, Standard, copied 2026-09-28.
            ("gpt-6-luna", ModelPrice(textIn: 0.10, cachedIn: 0.01, textOut: 0.50)),
            ("gpt-6-sol", ModelPrice(textIn: 2.00, cachedIn: 0.20, textOut: 10.00)),
            ("gpt-4o-transcribe-diarize", ModelPrice(textIn: 2.50, audioIn: 2.50, textOut: 10.00)),
        ]
    }

    /// OpenAI transcription models billed per audio minute, USD, same source.
    static let perMinute: [(prefix: String, price: Double)] = [
        ("gpt-transcribe", 0.0045),
        ("gpt-4o-mini-transcribe", 0.003),
        ("gpt-4o-transcribe", 0.006),
        ("whisper-1", 0.006),
        // ElevenLabs, from elevenlabs.io/pricing/api (copied 2026-09-28):
        // $0.22 an hour, the same on every plan.
        ("scribe_v2", 0.22 / 60),
    ]

    /// ElevenLabs' add-on for `keyterms` (the dictionary terms), same source.
    public static let elevenLabsKeytermsPerMinute = 0.05 / 60

    public static func perMinutePrice(for model: String) -> Double? {
        let id = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        return perMinute.filter { id.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.price
    }

    /// Price for a model ID, or nil when the pricing page has no entry.
    public static func price(for model: String, at date: Date = Date()) -> ModelPrice? {
        // Gateways label models `google/<id>`; the list price is the same.
        let id = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        return prices(at: date)
            .filter { id.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .price
    }

    /// Cost in USD, or nil for a model with no price entry.
    public static func cost(model: String, usage: TokenUsage, at date: Date = Date()) -> Double? {
        price(for: model, at: date)?.cost(usage)
    }

    // MARK: - Rupee list prices

    /// Sarvam lists prices in INR (docs.sarvam.ai/api-reference-docs/pricing,
    /// copied 2026-10-03): `sarvam-105b` per one million tokens, speech to
    /// text per hour billed per second, ₹45 with diarization. Rows are stored
    /// in USD at that day's rate (`FXRates`), so the Cost pane can show either.
    static let pricesINR: [(prefix: String, price: ModelPrice)] = [
        ("sarvam-105b", ModelPrice(textIn: 29.28, cachedIn: 10.98, textOut: 73.20)),
    ]

    static let perMinuteINR: [(prefix: String, price: Double)] = [
        ("saaras:v4:diarize", 45.0 / 60),
        ("saaras:v4", 30.0 / 60),
    ]

    /// Cost in INR for a model priced in rupees, or nil for every other model.
    public static func costINR(model: String, usage: TokenUsage) -> Double? {
        let id = model.lowercased()
        if let seconds = usage.audioSeconds,
           let perMinute = perMinuteINR.filter({ id.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count })?.price {
            return seconds / 60 * perMinute
        }
        return pricesINR.filter { id.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.price.cost(usage)
    }

    /// Whether the model's list price is in rupees.
    public static func isPricedInINR(model: String) -> Bool {
        let id = model.lowercased()
        return perMinuteINR.contains { id.hasPrefix($0.prefix) } || pricesINR.contains { id.hasPrefix($0.prefix) }
    }

    /// Audio tokens per second for estimation: the transcribe models bill 25,
    /// every other Gemini model 32 (both from the pricing page).
    public static func audioTokensPerSecond(model: String) -> Double {
        model.lowercased().contains("transcribe") ? 25 : 32
    }
}
