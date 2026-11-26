import AppKit
import VoiceIQCore

/// Quits and opens VoiceiQ again, for a grant macOS applies only at launch
/// (System & App Protection Override on 27.3+, a stale Accessibility grant).
@MainActor
enum AppRestart {
    static func now() {
        // The new copy opens only once this process is gone: the single-instance
        // check at launch would otherwise quit it.
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try relaunch.run()
        } catch {
            Log.session.error("restart failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        Log.session.info("restarting to pick up a permission grant")
        NSApp.terminate(nil)
    }
}
