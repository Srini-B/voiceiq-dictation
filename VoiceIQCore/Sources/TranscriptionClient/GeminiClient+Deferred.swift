import Foundation
import os

/// A transcription request sent by someone else, for the iPhone keyboard's
/// dictations that outlive the keyboard (docs/IOS.md, "Dictation in the
/// keyboard"). The keyboard builds the request through the normal pipeline
/// with `capturesTranscription` on and hands it to a background `URLSession`;
/// whoever receives the answer runs the pipeline again with
/// `replayedTranscription` set, so the provider's answer is parsed, checked,
/// metered and written up exactly as one fetched here.
extension GeminiClient {
    /// While true, the first transcription request is not sent: `post`
    /// throws it as `CapturedTranscriptionRequest`.
    @TaskLocal public static var capturesTranscription = false
    /// The answer to the first transcription request, used instead of
    /// sending it. Later transcription requests (a retry) go out as usual.
    @TaskLocal public static var replayedTranscription: ReplayedResponse?

    /// The first transcription request this client sent since
    /// `forgetSentTranscription()`: what the iPhone keyboard hands to its
    /// background session, byte for byte the request it sent itself, so
    /// nothing is encoded twice. A recording longer than one chunk sends
    /// more; the first is the one the replay answers.
    public nonisolated var sentTranscription: URLRequest? { firstTranscription.withLock { $0 } }

    /// The provider answered a transcription request with success since
    /// `forgetSentTranscription()`, whether or not usage was metered: the
    /// keyboard must not hand that dictation over.
    public nonisolated var transcriptionAnswered: Bool { answeredTranscription.withLock { $0 } }

    public nonisolated func forgetSentTranscription() {
        firstTranscription.withLock { $0 = nil }
        answeredTranscription.withLock { $0 = false }
    }
}

/// The request `post` would have sent: URL, headers (with the key) and body.
public struct CapturedTranscriptionRequest: Error, Sendable {
    public let request: URLRequest
}

/// A provider's answer received elsewhere, handed out once.
public final class ReplayedResponse: Sendable {
    private let pending: OSAllocatedUnfairLock<(body: Data, status: Int)?>
    private let status: Int

    public init(body: Data, status: Int) {
        pending = OSAllocatedUnfairLock(initialState: (body, status))
        self.status = status
    }

    /// The provider transcribed this dictation: a successful answer was
    /// handed out, so a later failure (the writing model, Translate, Ask)
    /// must not send the recording again. A refusal handed out (a quota,
    /// no credits) leaves the dictation to the retry queue.
    public var transcribed: Bool {
        (200..<300).contains(status) && pending.withLock { $0 == nil }
    }

    func take(url: URL) -> (Data, URLResponse)? {
        guard let (body, status) = pending.withLock({ state in defer { state = nil }; return state }),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return nil }
        return (body, response)
    }
}
