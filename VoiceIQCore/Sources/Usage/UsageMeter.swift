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

    public init(mode: DictationMode, sessionID: String?) {
        switch mode {
        case .dictate: self.init(activity: .dictation, sessionID: sessionID)
        case .askAnything: self.init(activity: .askAnything, sessionID: sessionID)
        case .translate: self.init(activity: .translate, sessionID: sessionID)
        case .agent: self.init(activity: .agent, sessionID: sessionID)
        }
    }
}

/// The single write path into `UsageStore`. Only the model clients call
/// `record`.
public enum UsageMeter {
    @TaskLocal public static var scope: UsageScope?
    /// Length of the audio a transcription sends. Gateways charge MAI
    /// Transcribe 2 and OpenAI's transcription models by audio length but
    /// report only the charge, so the length comes from the sender.
    @TaskLocal public static var audioSeconds: Double?

    /// Set once at launch. Nil (tests, onboarding key checks) means calls are
    /// logged but not stored.
    nonisolated(unsafe) public static var store: UsageStore?

    public static func record(stage: UsageStage, model: String, usage: TokenUsage) {
        // Per-minute models report a charge and no tokens, or (Sarvam) only
        // the audio length, priced here.
        guard !usage.isEmpty || usage.reportedCostUSD != nil || usage.audioSeconds != nil else { return }
        var usage = usage
        if usage.isEmpty, usage.audioSeconds == nil { usage.audioSeconds = audioSeconds }
        let scope = self.scope ?? UsageScope(activity: .other, sessionID: nil)
        let record = UsageRecord(activity: scope.activity, stage: stage, model: model,
                                 sessionID: scope.sessionID, usage: usage)
        let cost = record.costUSD.map { String(format: "$%.5f", $0) } ?? "unpriced"
        Log.usage.info(
            "usage \(scope.activity.rawValue, privacy: .public)/\(stage.rawValue, privacy: .public) \(model, privacy: .public): in \(usage.totalIn, privacy: .public) (audio \(usage.audioIn, privacy: .public), image \(usage.imageIn, privacy: .public)) out \(usage.totalOut, privacy: .public)\(usage.isEstimated ? " est" : "", privacy: .public) \(cost, privacy: .public)"
        )
        store?.append(record)
        // No rate for the call's day yet: fetch it and give the row its rate.
        if record.fxRateINR == nil, let store { scheduleFXBackfill(store) }
    }

    private static let fxLock = NSLock()
    nonisolated(unsafe) private static var fxTask: Task<Void, Never>?

    /// One refresh and back-fill at a time: offline, every row of a long
    /// meeting arrives unrated, and each would otherwise start its own
    /// Frankfurter request and table scan.
    private static func scheduleFXBackfill(_ store: UsageStore) {
        fxLock.withLock {
            guard fxTask == nil else { return }
            fxTask = Task {
                await FXRates.refresh()
                await store.backfillFX()
                fxLock.withLock { fxTask = nil }
            }
        }
    }
}
