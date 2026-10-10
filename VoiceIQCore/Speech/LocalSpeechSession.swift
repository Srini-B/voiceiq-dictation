import Foundation

public protocol LocalSpeechSession: Actor {
    func load(from directory: URL) async
    /// Nil rejects the audio; otherwise the string is the display-only preview.
    func append(_ pcm: Data) async -> String?
    func transcribe(framesWritten: Int64) async -> String?
    func stop() async
}

public typealias LocalSpeechSessionFactory = @Sendable (LocalSpeechModel, URL, Bool) -> any LocalSpeechSession
