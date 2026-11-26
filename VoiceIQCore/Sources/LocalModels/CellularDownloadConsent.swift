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
    public enum Network: Sendable {
        case offline, wifi, cellular
        /// The monitor has not reported a path yet (its first update arrives
        /// just after it starts). Treated as cellular: asking costs a tap,
        /// guessing wrong costs the user's data or a false "No internet".
        case unknown

        /// Cellular, or a connection iOS marks expensive (a personal hotspot).
        /// Read from `NWPath` as Hex does: `usesInterfaceType(.cellular)` and
        /// `isExpensive` (anomalyco/hex 9e41970e, MIT).
        public init(satisfied: Bool, cellular: Bool, expensive: Bool) {
            if !satisfied { self = .offline } else { self = cellular || expensive ? .cellular : .wifi }
        }
    }

    public enum Decision: Equatable, Sendable {
        case start, ask
        /// Not started: the downloader retries a lost connection by itself,
        /// so a start with no network could come back on cellular unasked.
        case offline
    }

    /// Downloads in progress, by model folder name.
    private var started: Set<String> = []

    public init() {}

    /// What tapping Download or Retry does. Starting records consent, so the
    /// download carries on through drops and network changes.
    public mutating func tap(_ download: String, on network: Network) -> Decision {
        if started.contains(download) { return .start }
        switch network {
        case .offline: return .offline
        case .cellular, .unknown: return .ask
        case .wifi:
            started.insert(download)
            return .start
        }
    }

    /// The user agreed to download over cellular data.
    public mutating func confirm(_ download: String) {
        started.insert(download)
    }

    /// The download finished or was cancelled; the next one is a new download.
    public mutating func end(_ download: String) {
        started.remove(download)
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
    /// `.unknown` until the monitor's first update: `currentPath` before then reads
    /// as unsatisfied, which would refuse a download as offline.
    private var network: CellularDownloadConsent.Network = .unknown

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let network = CellularDownloadConsent.Network(
                satisfied: path.status == .satisfied,
                cellular: path.usesInterfaceType(.cellular),
                expensive: path.isExpensive
            )
            // Delivered on the main queue, in order; separate Tasks could reorder a quick handoff.
            MainActor.assumeIsolated { self?.network = network }
        }
        // Started ahead of the first tap so its first update has usually arrived.
        monitor.start(queue: .main)
    }

    /// Called as `store` is asked to download. `.ask` leaves `store` pending
    /// for the alert.
    func tap(_ store: LocalModelStore, id: String) -> CellularDownloadConsent.Decision {
        let decision = consent.tap(id, on: network)
        if decision == .ask { pending = store }
        return decision
    }

    func confirmed(id: String) {
        consent.confirm(id)
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
