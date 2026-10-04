import Foundation
import GRDB

/// Gives every row the rupee rate of its day. Rows made before the rate
/// existed, or while Frankfurter was unreachable, have none; the ECB series
/// goes back decades, so one range request covers them all.
extension UsageStore {
    func recordsMissingFX() -> [UsageRecord] {
        (try? queue.read { db in
            try UsageRecord.filter(Column("fxRateINR") == nil).order(Column("at")).fetchAll(db)
        }) ?? []
    }

    /// Writes each row's quote; a row priced only in rupees gets its USD
    /// cost at the same time.
    func setFX(_ quotes: [String: FXQuote], for records: [UsageRecord]) {
        do {
            try queue.write { db in
                for var record in records {
                    guard let quote = quotes[FXRates.utcDay(record.at)] else { continue }
                    record.fxRateINR = quote.inrPerUSD
                    record.fxDate = quote.date
                    if record.costUSD == nil {
                        // Rows booked before v4 have no `listINR`; price them now.
                        record.listINR = record.listINR ?? PriceBook.costINR(model: record.model, usage: record.usage)
                        record.costUSD = UsageRecord.usd(fromINR: record.listINR, fx: quote)
                    }
                    try record.update(db)
                }
            }
            NotificationCenter.default.post(name: .gtUsageDidChange, object: nil)
        } catch {
            Log.usage.error("UsageStore: setFX failed: \(error)")
        }
    }

    /// Fetches the rates the ledger is missing and writes them. Safe to call
    /// often: nothing is fetched when every row has one.
    public func backfillFX() async {
        let missing = recordsMissingFX()
        guard let first = missing.first, let last = missing.last else { return }
        let days = Set(missing.map { FXRates.utcDay($0.at) })
        // A week back covers a weekend and a holiday run before the first row.
        let start = FXRates.utcDay(FXRates.utcDay(first.at), adding: -7)
        do {
            let rates = try await FXRates.rates(from: start, to: FXRates.utcDay(last.at))
            let quotes = FXRates.quotes(for: Array(days), from: rates)
            setFX(quotes, for: missing)
            Log.usage.info("UsageStore: rates back-filled for \(quotes.count) of \(days.count) days, \(missing.count) rows")
        } catch {
            Log.usage.error("UsageStore: FX back-fill failed: \(error)")
        }
    }
}
