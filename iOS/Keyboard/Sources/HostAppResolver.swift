// Adapted from Dictus (github.com/getdictus/dictus-ios, MIT License,
// Copyright (c) 2026 PIVI Solutions). See THIRD_PARTY_NOTICES.md.

import ObjectiveC
import os
import UIKit

/// Which app the keyboard is typing into, so the app can send the user back
/// there after the one-time bounce. Uses private UIKit surfaces, all resolved at
/// runtime and guarded: a missing surface means no answer, never a crash.
///
/// Two facts are joined:
/// 1. `_UIKeyboardArbiterClient.currentClientState` names a (bundle ID, pid)
///    pair. On its own it is often stale (Dictus measured 7 of 16 appearances).
/// 2. `_hostProcessIdentifier` on our own input view controller is the host's
///    pid right now.
/// The arbiter's pairs go into a pid table; the current pid is looked up in it.
@MainActor
enum HostAppResolver {
    private static let arbiterClassNames = ["_UIKeyboardArbiterClient", "UIKeyboardArbiterClient"]
    private static let sharedClientSelector = "automaticSharedArbiterClient"
    private static var table = HostPidTable()
    private static let log = Logger(subsystem: "io.blue.voiceiq.ios.keyboard", category: "host")

    /// Call when the keyboard appears.
    static func keyboardWillAppear() {
        let activation = VIQHostArbiterActivation.activate()
        let connection = ensureArbiterConnection()
        log.info("arbiter \(activation, privacy: .public) (load \(VIQHostArbiterActivation.loadTimeOutcome(), privacy: .public)), connection \(connection, privacy: .public)")
        harvest()
    }

    /// Record what the arbiter says now. Cheap; call on every text change.
    static func harvest() {
        guard let state = currentClientState(),
              let bundleID = read("sourceBundleIdentifier", from: state) as? String,
              let pid = (read("processIdentifier", from: state) as? NSNumber)?.intValue
        else { return }
        table.record(bundleId: bundleID, forPid: pid)
    }

    /// The host's bundle ID, or nil when it cannot be known for certain.
    static func currentHost(for controller: UIInputViewController) -> String? {
        harvest()
        guard let pid = (read("_hostProcessIdentifier", from: controller) as? NSNumber)?.intValue, pid > 0 else {
            log.info("host unresolved: no host pid")
            KeyboardLog.note("host unresolved: no host pid")
            return nil
        }
        guard let bundleID = table.bundleId(forPid: pid) else {
            log.info("host unresolved: pid \(pid) not in table (\(table.count) known)")
            KeyboardLog.note("host unresolved: pid \(pid) not in table (\(table.count) known)")
            return nil
        }
        return bundleID
    }

    private static func ensureArbiterConnection() -> String {
        guard let client = sharedClient() else { return "no-client" }
        guard read("connection", from: client) == nil else { return "connected" }
        let selector = NSSelectorFromString("startConnection")
        guard client.responds(to: selector) else { return "no-selector" }
        _ = client.perform(selector)
        return "started"
    }

    private static func currentClientState() -> NSObject? {
        sharedClient().flatMap { read("currentClientState", from: $0) as? NSObject }
    }

    private static func sharedClient() -> NSObject? {
        guard let cls = arbiterClassNames.lazy.compactMap({ NSClassFromString($0) as? NSObject.Type }).first else {
            return nil
        }
        let selector = NSSelectorFromString(sharedClientSelector)
        let classObject = cls as AnyObject
        guard classObject.responds(to: selector) else { return nil }
        return classObject.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func read(_ key: String, from object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }
}

/// Bundle IDs by pid, as the arbiter reported them.
///
/// The arbiter is often stale: on appearance it can still name the previous
/// host. But every pair it reports was true, and stays true while that
/// process lives, so entries are kept across appearances and a host seen
/// once in this keyboard process resolves from then on. iOS hands out pids in
/// sequence and wraps only at 99,999, so an entry naming a different, newer
/// process on the same pid would need a wrap within this keyboard's life.
struct HostPidTable {
    static let maxEntries = 64
    private var entries: [Int: String] = [:]
    private var insertionOrder: [Int] = []

    var count: Int { entries.count }

    mutating func record(bundleId: String, forPid pid: Int) {
        guard !bundleId.isEmpty, pid > 0 else { return }
        if entries[pid] == nil {
            insertionOrder.append(pid)
            if insertionOrder.count > Self.maxEntries {
                entries[insertionOrder.removeFirst()] = nil
            }
        }
        entries[pid] = bundleId
    }

    func bundleId(forPid pid: Int) -> String? {
        entries[pid]
    }
}
