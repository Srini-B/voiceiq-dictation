import Foundation
import VoiceIQBridge
import VoiceIQCore

/// The last few hundred session events (session starts, background mic starts), kept
/// in a file so a TestFlight user can copy them from Settings › Advanced.
/// No transcript text or keys go in here.
enum SessionDiagnostics {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("session-log.txt")
    private static let queue = DispatchQueue(label: "io.blue.voiceiq.session-log")
    private static let maxLines = 400
    /// Set by the first note, which the voice session writes at launch.
    private static let launched = Date()

    /// "process up 3s": how long this process has run, so a load time can be
    /// read against a fresh launch or a process iOS kept from the last dictation.
    static var processAge: String {
        String(format: "process up %.0fs", Date().timeIntervalSince(launched))
    }

    static func note(_ line: String) {
        _ = launched
        Log.session.info("\(line, privacy: .public)")
        let stamp = SharedStore.logStamp(Date())
        queue.async {
            var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
            lines.append("\(stamp) \(line)")
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func read() -> String {
        queue.sync { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}
