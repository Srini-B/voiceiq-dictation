#if os(macOS)
import Darwin
import Foundation
import VoiceIQBridge

/// The native messaging host of the VoiceiQ Meetings Chrome extension. Chrome
/// starts it from the manifest VoiceiQ installs (`BrowserExtension` in the
/// app) and talks to it over stdin: each message is a 4-byte length in native
/// byte order, then that many bytes of JSON. Every speaker event goes to
/// `BrowserSpeakerLog`; the app is not involved until a meeting stops, so the
/// extension works whether VoiceiQ is running or not.
public enum BrowserHostServer {
    /// Chrome passes the calling extension's origin as the first argument.
    public static func isBrowserLaunch(_ arguments: [String]) -> Bool {
        arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true
    }

    /// Messages larger than this are not speaker events; Chrome sends at most 64 MiB.
    static let largestMessage = 64 * 1024

    public static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // Old days go even when no meeting is ever recorded: at start, and
        // hourly, since Chrome keeps a host running while the browser is open.
        BrowserSpeakerLog.prune()
        var pruned = Date()
        let origin = CommandLine.arguments.dropFirst().first ?? "?"
        note("host started by \(origin)")
        var received = 0, unreadable = 0, failed = 0
        var sites: Set<String> = []
        let input = FileHandle.standardInput
        while let length = read(4, from: input).map({ $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }) {
            guard length <= largestMessage else {
                note("message of \(length) bytes is too large, closing", level: "error")
                break
            }
            guard let body = read(Int(length), from: input) else { break }
            guard let event = try? JSONDecoder().decode(BrowserSpeakerEvent.self, from: body) else {
                unreadable += 1
                continue
            }
            received += 1
            // The site only: the meeting code in the path names the meeting.
            let site = String(event.page.prefix { $0 != "/" })
            if sites.insert(site).inserted { note("speaker events from \(site), tab \(event.tab)") }
            do { try BrowserSpeakerLog.append(event) } catch {
                failed += 1
                if failed == 1 { note("couldn't save a speaker event: \(error)", level: "error") }
            }
            if Date().timeIntervalSince(pruned) > 3600 { BrowserSpeakerLog.prune(); pruned = Date() }
        }
        note("host stopped after \(received) events (\(unreadable) unreadable, \(failed) not saved)")
        DebugLog.flush()
        exit(0)
    }

    private static func note(_ message: String, level: String = "info") {
        DebugLog.write(level: level, category: "chrome-extension", message)
    }

    private static func read(_ count: Int, from handle: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
            data += chunk
        }
        return data
    }
}
#endif
