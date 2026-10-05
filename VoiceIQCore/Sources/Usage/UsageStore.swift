import Foundation
import GRDB

/// What the user was doing when a model call happened.
public enum UsageActivity: String, Codable, CaseIterable, Sendable {
    case dictation, askAnything, translate, meeting, agent, other

    public var displayName: String {
        switch self {
        case .dictation: return "Dictation"
        case .askAnything: return "Ask Anything"
        case .translate: return "Translate"
        case .meeting: return "Meetings"
        case .agent: return "Agent"
        case .other: return "Other"
        }
    }
}

/// Which call inside that activity. One dictation is typically a
/// transcription plus a cleanup; one meeting is a transcription plus a summary.
public enum UsageStage: String, Codable, Sendable {
    case transcribe, cleanup, answer, translate, webQuery, meetingTranscribe, meetingSummary, agentStep

    public var displayName: String {
        switch self {
        case .transcribe: return "Transcription"
        case .cleanup: return "Cleanup"
        case .answer: return "Answer"
        case .translate: return "Translation"
        case .webQuery: return "Web query"
        case .meetingTranscribe: return "Meeting transcription"
        case .meetingSummary: return "Meeting notes"
        case .agentStep: return "Agent step"
        }
    }
}

/// One billed model call.
public struct UsageRecord: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "usage"

    public var id: String
    public var at: Date
    public var activity: String
    public var stage: String
    public var model: String
    /// Dictation session UUID or meeting ID, so History can show per-item cost.
    public var sessionID: String?
    public var textIn: Int
    public var audioIn: Int
    public var imageIn: Int
    public var cachedIn: Int
    public var textOut: Int
    public var audioOut: Int
    public var thoughtOut: Int
    public var isEstimated: Bool
    /// Paid-tier USD at the time of the call; nil when the model is unpriced.
    public var costUSD: Double?
    /// Seconds of audio billed, for models priced by audio length. Nil on
    /// token-priced calls and on audio-priced calls booked before v2.
    public var audioSeconds: Double?

    public init(at: Date = Date(), activity: UsageActivity, stage: UsageStage, model: String,
                sessionID: String?, usage: TokenUsage) {
        self.id = UUID().uuidString
        self.at = at
        self.activity = activity.rawValue
        self.stage = stage.rawValue
        self.model = model
        self.sessionID = sessionID
        self.textIn = usage.textIn; self.audioIn = usage.audioIn; self.imageIn = usage.imageIn
        self.cachedIn = usage.cachedIn; self.textOut = usage.textOut; self.audioOut = usage.audioOut
        self.thoughtOut = usage.thoughtOut; self.isEstimated = usage.isEstimated
        // A stated charge (per-minute models) wins; the price book is for
        // models that only report tokens.
        self.costUSD = usage.reportedCostUSD ?? PriceBook.cost(model: model, usage: usage, at: at)
        self.audioSeconds = usage.audioSeconds
    }

    public var usage: TokenUsage {
        TokenUsage(textIn: textIn, audioIn: audioIn, imageIn: imageIn, cachedIn: cachedIn,
                   textOut: textOut, audioOut: audioOut, thoughtOut: thoughtOut, isEstimated: isEstimated,
                   audioSeconds: audioSeconds)
    }
    public var activityValue: UsageActivity { UsageActivity(rawValue: activity) ?? .other }
    public var stageValue: UsageStage? { UsageStage(rawValue: stage) }
}

public extension Notification.Name {
    static let gtUsageDidChange = Notification.Name("io.blue.voiceiq.usage-changed")
}

/// Append-only ledger of model calls, separate from history.sqlite so
/// deleting a dictation's audio never erases what it cost.
public final class UsageStore: @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try migrate()
    }

    public static func standard() throws -> UsageStore {
        try UsageStore(databaseURL: FileLayout.appSupportRoot.appendingPathComponent("usage.sqlite"))
    }

    public static func inMemory() throws -> UsageStore {
        try UsageStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceiq-usage-\(UUID().uuidString).sqlite"))
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: UsageRecord.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("at", .datetime).notNull().indexed()
                t.column("activity", .text).notNull().indexed()
                t.column("stage", .text).notNull()
                t.column("model", .text).notNull().indexed()
                t.column("sessionID", .text).indexed()
                for column in ["textIn", "audioIn", "imageIn", "cachedIn", "textOut", "audioOut", "thoughtOut"] {
                    t.column(column, .integer).notNull().defaults(to: 0)
                }
                t.column("isEstimated", .boolean).notNull().defaults(to: false)
                t.column("costUSD", .double)
            }
        }
        migrator.registerMigration("v2-audioSeconds") { db in
            try db.alter(table: UsageRecord.databaseTableName) { t in
                t.add(column: "audioSeconds", .double)
            }
        }
        // v3 and v4 added rupee columns for the removed Sarvam integration.
        // They stay registered so existing databases keep a known history;
        // nothing reads or writes the columns any more.
        migrator.registerMigration("v3-fx") { db in
            try db.alter(table: UsageRecord.databaseTableName) { t in
                t.add(column: "fxRateINR", .double)
                t.add(column: "fxDate", .text)
            }
        }
        migrator.registerMigration("v4-listINR") { db in
            try db.alter(table: UsageRecord.databaseTableName) { t in
                t.add(column: "listINR", .double)
            }
        }
        try migrator.migrate(queue)
    }

    // MARK: - Writes

    public func append(_ record: UsageRecord) {
        do {
            try queue.write { db in try record.insert(db) }
            NotificationCenter.default.post(name: .gtUsageDidChange, object: nil)
        } catch {
            Log.usage.error("UsageStore: append failed: \(error)")
        }
    }

    public func deleteAll() {
        do {
            _ = try queue.write { db in try UsageRecord.deleteAll(db) }
            NotificationCenter.default.post(name: .gtUsageDidChange, object: nil)
        } catch {
            Log.usage.error("UsageStore: deleteAll failed: \(error)")
        }
    }

    // MARK: - Reads

    public struct Total: Equatable, Sendable {
        public var costUSD: Double
        public var calls: Int
        public var tokensIn: Int
        public var tokensOut: Int
        /// Seconds of audio billed by length (see `UsageRecord.audioSeconds`).
        public var audioSeconds: Double
        /// True when any call in the total had no price entry or estimated tokens.
        public var isApproximate: Bool
        public static let zero = Total(costUSD: 0, calls: 0, tokensIn: 0, tokensOut: 0, audioSeconds: 0, isApproximate: false)
    }

    /// `source` limits every read to that source's models (see
    /// `CostSource.modelPrefixes`); nil reads everything.
    public func total(since start: Date? = nil, source: CostSource? = nil) -> Total {
        totals(groupedBy: nil, since: start, source: source).first?.total ?? .zero
    }

    public func totalsByActivity(since start: Date? = nil, source: CostSource? = nil) -> [(key: String, total: Total)] {
        totals(groupedBy: "activity", since: start, source: source)
    }

    public func totalsByModel(since start: Date? = nil, source: CostSource? = nil) -> [(key: String, total: Total)] {
        totals(groupedBy: "model", since: start, source: source)
    }

    private static func sourceFilter(_ source: CostSource) -> (sql: String, arguments: [String]) {
        let prefixes = source.modelPrefixes
        return ("(" + prefixes.map { _ in "LOWER(model) LIKE ?" }.joined(separator: " OR ") + ")",
                prefixes.map { $0 + "%" })
    }

    private func totals(groupedBy column: String?, since start: Date?, source: CostSource?) -> [(key: String, total: Total)] {
        let keyExpression = column ?? "''"
        var sql = """
            SELECT \(keyExpression) AS key,
                   COALESCE(SUM(costUSD), 0) AS cost,
                   COUNT(*) AS calls,
                   COALESCE(SUM(textIn + audioIn + imageIn + cachedIn), 0) AS tokensIn,
                   COALESCE(SUM(textOut + audioOut + thoughtOut), 0) AS tokensOut,
                   COALESCE(SUM(audioSeconds), 0) AS audioSeconds,
                   MAX(CASE WHEN costUSD IS NULL OR isEstimated THEN 1 ELSE 0 END) AS approx
            FROM usage
            """
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let start {
            conditions.append("at >= ?")
            arguments += [start]
        }
        if let source {
            let filter = Self.sourceFilter(source)
            conditions.append(filter.sql)
            arguments += StatementArguments(filter.arguments)
        }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if let column { sql += " GROUP BY \(column) ORDER BY cost DESC" }
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                    (row["key"] as String,
                     Total(costUSD: row["cost"], calls: row["calls"], tokensIn: row["tokensIn"],
                           tokensOut: row["tokensOut"], audioSeconds: row["audioSeconds"], isApproximate: (row["approx"] as Int? ?? 0) == 1))
                }
            }
        } catch {
            Log.usage.error("UsageStore: totals failed: \(error)")
            return []
        }
    }

    /// Cost per session for the History list. Nil entries mean unpriced.
    public func costBySession(ids: [String]) -> [String: Double] {
        guard !ids.isEmpty else { return [:] }
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT sessionID, SUM(costUSD) AS cost FROM usage WHERE sessionID IN (\(databaseQuestionMarks(count: ids.count))) GROUP BY sessionID",
                    arguments: StatementArguments(ids)
                )
                var result: [String: Double] = [:]
                for row in rows {
                    if let id = row["sessionID"] as String?, let cost = row["cost"] as Double? { result[id] = cost }
                }
                return result
            }
        } catch {
            Log.usage.error("UsageStore: costBySession failed: \(error)")
            return [:]
        }
    }

    public func records(forSession id: String) -> [UsageRecord] {
        (try? queue.read { db in
            try UsageRecord.filter(Column("sessionID") == id).order(Column("at")).fetchAll(db)
        }) ?? []
    }

    public func recent(limit: Int = 50, source: CostSource? = nil) -> [UsageRecord] {
        (try? queue.read { db in
            var request = UsageRecord.order(Column("at").desc)
            if let source {
                let filter = Self.sourceFilter(source)
                request = request.filter(sql: filter.sql, arguments: StatementArguments(filter.arguments))
            }
            return try request.limit(limit).fetchAll(db)
        }) ?? []
    }
}
