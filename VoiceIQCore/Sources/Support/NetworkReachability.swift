import Foundation
import Network
import os

/// One-shot connectivity snapshot — for flows that must distinguish "your key is
/// wrong" from "you're offline" (onboarding key validation).
public enum NetworkReachability {
    public static func probablyOnline(timeout: TimeInterval = 1.0) -> Bool {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        let satisfied = OSAllocatedUnfairLock(initialState: false)
        monitor.pathUpdateHandler = { path in
            satisfied.withLock { $0 = path.status == .satisfied }
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue(label: "io.blue.voiceiq.reachability"))
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        return satisfied.withLock { $0 }
    }
}
