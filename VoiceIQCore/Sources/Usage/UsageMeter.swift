import Foundation

/// Which user action a model call belongs to. Carried as a task-local so the
/// transport can attribute every call without threading a parameter through
/// the transcription service, the coordinator, and the retry queue.
public struct UsageScope: Equatable, Sendable {
    public var activity: UsageActivity
    public var sessionID: String?

    public init(activity: UsageActivity, sessionID: String?) {
        self.activity = activity
        self.sessionID = sessionID
    }
}

/// The single write path into `UsageStore`. Only the model clients call
/// `record`.
public enum UsageMeter {
    @TaskLocal public static var scope: UsageScope?

    /// Set once at launch. Nil (tests, onboarding key checks) means calls are
    /// logged but not stored.
    nonisolated(unsafe) public static var store: UsageStore?

    public static func record(stage: UsageStage, model: String, usage: TokenUsage) {
        guard !usage.isEmpty || usage.reportedCostUSD != nil else { return }
        let scope = self.scope ?? UsageScope(activity: .other, sessionID: nil)
        let record = UsageRecord(activity: scope.activity, stage: stage, model: model,
                                 sessionID: scope.sessionID, usage: usage)
        let cost = record.costUSD.map { String(format: "$%.5f", $0) } ?? "unpriced"
        Log.usage.info(
            "usage \(scope.activity.rawValue, privacy: .public)/\(stage.rawValue, privacy: .public) \(model, privacy: .public): in \(usage.totalIn, privacy: .public) (audio \(usage.audioIn, privacy: .public), image \(usage.imageIn, privacy: .public), cached \(usage.cachedIn, privacy: .public)) out \(usage.totalOut, privacy: .public)\(usage.isEstimated ? " est" : "", privacy: .public) \(cost, privacy: .public)"
        )
        store?.append(record)
    }
}
