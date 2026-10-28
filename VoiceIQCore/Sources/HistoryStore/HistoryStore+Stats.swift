import Foundation
import GRDB

/// What the History stats count for one dictation, without its text. Rows are
/// written with the dictation and never deleted, so deleting, clearing or
/// expiring History leaves the stats alone. They share `history.sqlite`, so
/// when a corrupt index is quarantined and rebuilt, only dictations whose
/// folders remain are counted again.
struct DictationStat: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dictationStat"

    var id: String
    var startedAt: Date
    var words: Int
    var durationSeconds: Double?

    /// Nil until the dictation has a cleaned transcript.
    init?(_ record: DictationRecord) {
        guard let text = record.cleanedTranscript else { return nil }
        id = record.id
        startedAt = record.startedAt
        // Whitespace-aware split (newlines count too — audit L29).
        words = text.split(whereSeparator: \.isWhitespace).count
        durationSeconds = record.durationSeconds
    }
}

extension HistoryStore {
    /// Called in the transaction that writes the dictation row. A Retry that
    /// changes the text replaces the dictation's stat.
    static func recordStat(of record: DictationRecord, in db: Database) throws {
        try DictationStat(record)?.save(db)
    }

    /// Migration: the table, filled from the History that exists today.
    static func createStatTable(_ db: Database) throws {
        try db.create(table: DictationStat.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("startedAt", .datetime).notNull()
            t.column("words", .integer).notNull()
            t.column("durationSeconds", .double)
        }
        for record in try DictationRecord.fetchAll(db) {
            try recordStat(of: record, in: db)
        }
    }

    /// Rolling windows ending now, each starting at midnight.
    public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
        case today, week, month, year, allTime

        public var id: Self { self }

        public var title: String {
            switch self {
            case .today: return "Today"
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            case .year: return "Last 12 months"
            case .allTime: return "All time"
            }
        }

        func start(now: Date, calendar: Calendar) -> Date? {
            let today = calendar.startOfDay(for: now)
            switch self {
            case .today: return today
            case .week: return calendar.date(byAdding: .day, value: -6, to: today)
            case .month: return calendar.date(byAdding: .day, value: -29, to: today)
            case .year: return calendar.date(byAdding: .month, value: -12, to: today)
            case .allTime: return nil
            }
        }
    }

    public struct Stats: Equatable, Sendable {
        public var totalWords: Int
        public var totalDictations: Int
        public var averageWPM: Int
        /// Recorded audio across the same dictations. Transcription is billed
        /// by audio time, so this is the figure to hold against a price per hour.
        public var totalAudioSeconds: Double
        /// Calendar days with at least one dictation, over all time.
        public var activeDays: Int
        /// Consecutive days up to today (or yesterday, when today has none
        /// yet), over all time: the period does not cut a streak short.
        public var currentStreak: Int
        public var longestStreak: Int

        public init(totalWords: Int, totalDictations: Int, averageWPM: Int, totalAudioSeconds: Double = 0,
                    activeDays: Int = 0, currentStreak: Int = 0, longestStreak: Int = 0) {
            self.totalWords = totalWords
            self.totalDictations = totalDictations
            self.averageWPM = averageWPM
            self.totalAudioSeconds = totalAudioSeconds
            self.activeDays = activeDays
            self.currentStreak = currentStreak
            self.longestStreak = longestStreak
        }

        /// Words per minute a person types, for the time-saved figure. 40 is
        /// the usual average for a non-professional typist.
        public static let typingWPM = 40.0

        /// Minutes typing the same words would have taken, less the minutes
        /// spent speaking them. Zero when speaking was not faster.
        public var minutesSaved: Int {
            max(0, Int((Double(totalWords) / Self.typingWPM - totalAudioSeconds / 60).rounded()))
        }

        /// "38 min" under an hour, then hours.
        public var savedLabel: String {
            let minutes = minutesSaved
            if minutes < 60 { return minutes > 0 ? "\(minutes) min" : "–" }
            let hours = Double(minutes) / 60
            return hours < 100 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h"
        }

        /// "42 min" under an hour, then hours: "3.2 h", "148 h".
        public var audioLabel: String {
            let seconds = totalAudioSeconds
            if seconds < 60 { return seconds > 0 ? "\(Int(seconds.rounded())) s" : "–" }
            if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) min" }
            let hours = seconds / 3_600
            return hours < 100 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h"
        }
    }

    /// Every dictation ever transcribed in `period`, including those since
    /// deleted from History.
    public func stats(period: StatsPeriod = .allTime, now: Date = Date(), calendar: Calendar = .current) -> Stats {
        (try? queue.read { db in
            let start = period.start(now: now, calendar: calendar) ?? .distantPast
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS dictations, IFNULL(SUM(words), 0) AS words,
                       IFNULL(SUM(CASE WHEN durationSeconds > 0 THEN words END), 0) AS timedWords,
                       IFNULL(SUM(CASE WHEN durationSeconds > 0 THEN durationSeconds END), 0) AS speech
                FROM dictationStat WHERE startedAt >= ?
                """, arguments: [start])
            let words: Int = row?["words"] ?? 0
            let timedWords: Int = row?["timedWords"] ?? 0
            let speech: Double = row?["speech"] ?? 0
            // Streaks need calendar days, which only Calendar can draw in the
            // user's time zone, so the dates themselves are read.
            let days = Set(try Date.fetchAll(db, sql: "SELECT startedAt FROM dictationStat").map(calendar.startOfDay))
            // WPM only over rows that actually have a duration.
            let wpm = speech > 10 ? Int(Double(timedWords) / (speech / 60)) : 0
            let streaks = Self.streaks(days: days, now: now, calendar: calendar)
            return Stats(totalWords: words, totalDictations: row?["dictations"] ?? 0, averageWPM: wpm, totalAudioSeconds: speech,
                         activeDays: days.count, currentStreak: streaks.current, longestStreak: streaks.longest)
        }) ?? Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    }

    /// The run of consecutive days ending today or yesterday, and the
    /// longest run anywhere. A day with no dictation yet does not break the
    /// streak until it is over.
    static func streaks(days: Set<Date>, now: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }
        let sorted = days.sorted()
        var longest = 1
        var run = 1
        for (previous, day) in zip(sorted, sorted.dropFirst()) {
            run = calendar.dateComponents([.day], from: previous, to: day).day == 1 ? run + 1 : 1
            longest = max(longest, run)
        }
        let today = calendar.startOfDay(for: now)
        var current = 0
        var cursor = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while days.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }
}
