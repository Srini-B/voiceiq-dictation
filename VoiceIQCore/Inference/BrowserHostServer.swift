#if os(macOS)
import Darwin
import Foundation
import VoiceIQSpeech

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
        // Chrome starts a host with each browser start, so old days go even
        // when no meeting is ever recorded.
        BrowserSpeakerLog.prune()
        let input = FileHandle.standardInput
        while let length = read(4, from: input).map({ $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }),
              length <= largestMessage, let body = read(Int(length), from: input) {
            guard let event = try? JSONDecoder().decode(BrowserSpeakerEvent.self, from: body) else { continue }
            try? BrowserSpeakerLog.append(event)
        }
        exit(0)
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
