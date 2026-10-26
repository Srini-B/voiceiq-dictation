import Foundation

public struct LocalSpeechOptions: Codable, Sendable {
    public struct Term: Codable, Sendable {
        public let text: String
        public let aliases: [String]
        public init(text: String, aliases: [String] = []) {
            self.text = text
            self.aliases = aliases
        }
    }
    public var vocabulary: [Term]
    public var toolsDirectory: URL?
    /// Locale code Nemotron is prompted with. Fluid Speech Mini ignores it.
    public var language: String
    public init(vocabulary: [Term] = [], toolsDirectory: URL? = nil, language: String = "en-US") {
        self.vocabulary = vocabulary
        self.toolsDirectory = toolsDirectory
        self.language = language
    }
}

public struct LocalSpeechOutput: Codable, Sendable, Equatable {
    public let original: String
    public let normalized: String
    public let confidence: Float?
    public init(original: String, normalized: String, confidence: Float? = nil) {
        self.original = original
        self.normalized = normalized
        self.confidence = confidence
    }
}

public protocol LocalSpeechSession: Actor {
    /// False when the model did not load; `transcribe` then returns nil.
    @discardableResult
    func load(from directory: URL) async -> Bool
    /// Nil rejects the audio; otherwise the string is the display-only preview.
    func append(_ pcm: Data) async -> String?
    func transcribe(framesWritten: Int64) async -> LocalSpeechOutput?
    func stop() async
}

public typealias LocalSpeechSessionFactory = @Sendable (LocalSpeechModel, URL, Bool, LocalSpeechOptions) -> any LocalSpeechSession
