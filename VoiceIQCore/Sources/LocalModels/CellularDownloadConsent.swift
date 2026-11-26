import Foundation
#if os(iOS)
import Network
#endif

/// Whether starting a model download on the iPhone first asks about cellular
/// data. It asks once per download: a download that started, on Wi-Fi or
/// after the user confirmed, never asks again, even when the network drops
/// and comes back or moves to cellular, until it finishes or is cancelled.
/// The next download of the same model asks again. Downloads are never held
/// for Wi-Fi (Hex holds them, anomalyco/hex 9e41970e; VoiceiQ asks instead).
public struct CellularDownloadConsent: Equatable, Sendable {
    /// Downloads in progress, by model folder name.
    private var started: Set<String> = []

    public init() {}

    public func shouldAsk(for download: String, onCellular: Bool) -> Bool {
        onCellular && !started.contains(download)
    }

    /// The download started: on Wi-Fi, or on cellular after the user confirmed.
    public mutating func begin(_ download: String) {
        started.insert(download)
    }

    /// The download finished or was cancelled; the next one is a new download.
    public mutating func end(_ download: String) {
        started.remove(download)
    }

    /// Cellular, or a connection iOS marks expensive (a personal hotspot).
    /// Read from `NWPath` as Hex does: `usesInterfaceType(.cellular)` and
    /// `isExpensive` (anomalyco/hex 9e41970e, MIT).
    public static func isCellular(satisfied: Bool, cellular: Bool, expensive: Bool) -> Bool {
        satisfied && (cellular || expensive)
    }
}

#if os(iOS)
/// The iPhone's side of `CellularDownloadConsent`: watches the network and
/// holds the download waiting for the user's answer. Settings shows the alert
/// while `pending` is set.
@MainActor
public final class CellularModelDownloads: ObservableObject {
    public static let shared = CellularModelDownloads()

    /// The model whose download waits for the cellular data alert.
    @Published public var pending: LocalModelStore?
    private var consent = CellularDownloadConsent()
    private let monitor = NWPathMonitor()

    private init() {
        // Started ahead of the first tap: a monitor reports its path only
        // after it has started.
        monitor.start(queue: DispatchQueue(label: "io.blue.voiceiq.model-download-network", qos: .utility))
    }

    private var onCellular: Bool {
        let path = monitor.currentPath
        return CellularDownloadConsent.isCellular(
            satisfied: path.status == .satisfied,
            cellular: path.usesInterfaceType(.cellular),
            expensive: path.isExpensive
        )
    }

    /// Called as `store` starts its download. True when the alert must
    /// answer first; `store` is then pending.
    func needsConfirmation(_ store: LocalModelStore, id: String) -> Bool {
        guard consent.shouldAsk(for: id, onCellular: onCellular) else { return false }
        pending = store
        return true
    }

    func began(id: String) {
        consent.begin(id)
    }

    func ended(id: String) {
        consent.end(id)
    }

    /// Download over cellular, from the alert.
    public func confirm(_ store: LocalModelStore) {
        pending = nil
        store.startConfirmedDownload()
    }
}
#endif
