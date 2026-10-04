import Foundation

/// One day's USD→INR rate, as recorded on every usage row made while it was
/// current. Sarvam lists its prices in rupees and the Cost pane shows either
/// currency, so each call keeps the rate it was converted at.
public struct FXQuote: Codable, Equatable, Sendable {
    public var inrPerUSD: Double
    /// The quote's own date (`YYYY-MM-DD`), the last business day the ECB
    /// published; a Saturday call carries Friday's date.
    public var date: String
    public var fetchedAt: Date

    public init(inrPerUSD: Double, date: String, fetchedAt: Date = Date()) {
        self.inrPerUSD = inrPerUSD; self.date = date; self.fetchedAt = fetchedAt
    }
}

/// ECB reference rates from Frankfurter (api.frankfurter.dev, free, no key;
/// checked 2026-10-03). `latest` answers `{"date": "...", "rates": {"INR":
/// 96.32}}`; a `YYYY-MM-DD..YYYY-MM-DD` path answers one entry per business
/// day. The ECB publishes once a day around 16:00 CET, so the cached quote is
/// refreshed at most every few hours and otherwise read synchronously at
/// record time.
public enum FXRates {
    static let base = URL(string: "https://api.frankfurter.dev/v1")!
    static let defaultsKey = "fxQuoteINR"
    static let maxAge: TimeInterval = 4 * 3600
    nonisolated(unsafe) static var defaults = UserDefaults.standard

    public static func cachedQuote() -> FXQuote? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(FXQuote.self, from: data)
    }

    static func store(_ quote: FXQuote) {
        if let data = try? JSONEncoder().encode(quote) { defaults.set(data, forKey: defaultsKey) }
    }

    /// Fetches today's quote unless the cached one is recent. Never throws:
    /// a failed refresh leaves the cache as it was and the row is back-filled
    /// later by `UsageStore.backfillFX`.
    public static func refresh() async {
        if let cached = cachedQuote(), Date().timeIntervalSince(cached.fetchedAt) < maxAge { return }
        do {
            store(try await latest())
        } catch {
            Log.usage.error("FXRates: refresh failed: \(error)")
        }
    }

    public static func latest() async throws -> FXQuote {
        let data = try await get(path: "latest")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = json["date"] as? String,
              let rate = ((json["rates"] as? [String: Any])?["INR"] as? NSNumber)?.doubleValue else {
            throw URLError(.cannotParseResponse)
        }
        return FXQuote(inrPerUSD: rate, date: date)
    }

    /// INR per USD for each business day in the range, keyed by date.
    public static func rates(from start: String, to end: String) async throws -> [String: Double] {
        let data = try await get(path: "\(start)..\(end)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: [String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return rates.compactMapValues { ($0["INR"] as? NSNumber)?.doubleValue }
    }

    /// The quote that applied on each date: that day's rate when the ECB
    /// published one, otherwise the nearest earlier day's (weekends and
    /// holidays). Dates before the first published day get nothing.
    static func quotes(for dates: [String], from rates: [String: Double]) -> [String: FXQuote] {
        let published = rates.keys.sorted()
        var result: [String: FXQuote] = [:]
        for date in dates {
            guard let day = published.last(where: { $0 <= date }), let rate = rates[day] else { continue }
            result[date] = FXQuote(inrPerUSD: rate, date: day)
        }
        return result
    }

    private static func get(path: String) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "base", value: "USD"), URLQueryItem(name: "symbols", value: "INR")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// `YYYY-MM-DD` in UTC, the calendar the ledger's `date(at)` uses.
    public static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `YYYY-MM-01` of the day's month.
    public static func utcMonthStart(_ day: String) -> String {
        String(day.prefix(7)) + "-01"
    }

    public static func utcDay(_ day: String, adding days: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return day }
        return formatter.string(from: date.addingTimeInterval(Double(days) * 86_400))
    }
}
