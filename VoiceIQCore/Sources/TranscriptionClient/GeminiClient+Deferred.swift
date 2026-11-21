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
}

/// The request `post` would have sent: URL, headers (with the key) and body.
public struct CapturedTranscriptionRequest: Error, Sendable {
    public let request: URLRequest
}

/// A provider's answer received elsewhere, handed out once.
public final class ReplayedResponse: Sendable {
    private let pending: OSAllocatedUnfairLock<(body: Data, status: Int)?>

    public init(body: Data, status: Int) {
        pending = OSAllocatedUnfairLock(initialState: (body, status))
    }

    /// The answer was handed out: the provider transcribed this dictation,
    /// so a later failure (the writing model, Translate, Ask) must not send
    /// the recording again.
    public var wasTaken: Bool { pending.withLock { $0 == nil } }

    func take(url: URL) -> (Data, URLResponse)? {
        guard let (body, status) = pending.withLock({ state in defer { state = nil }; return state }),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return nil }
        return (body, response)
    }
}
