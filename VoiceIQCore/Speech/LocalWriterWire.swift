import Foundation

/// One generation by the on-device writer (LFM3-Omni-2B): load the model,
/// write one answer, free everything. Nothing stays in memory between
/// requests. `system` is the part that never changes; its processed state is
/// saved to `prefixCache` the first time and read back after that, so a
/// dictation processes only its own text.
public struct LocalWriteRequest: Codable, Sendable {
    public var model: URL
    public var system: String
    public var user: String
    /// GBNF the answer must match, or nil for free text.
    public var grammar: String?
    public var maxTokens: Int
    /// The most context the request may use: prompt plus answer.
    public var maxContext: Int
    public var prefixCache: URL?
    /// Metal on the Mac. iOS refuses GPU work from an app in the background,
    /// where VoiceiQ writes a dictation, so the phone runs on the CPU.
    public var useGPU: Bool

    public init(model: URL, system: String, user: String, grammar: String?, maxTokens: Int,
                maxContext: Int, prefixCache: URL?, useGPU: Bool) {
        self.model = model; self.system = system; self.user = user; self.grammar = grammar
        self.maxTokens = maxTokens; self.maxContext = maxContext; self.prefixCache = prefixCache; self.useGPU = useGPU
    }
}

public struct LocalWriteResult: Codable, Sendable, Equatable {
    public var text: String
    public var promptTokens: Int
    /// Prompt tokens read back from the prefix cache instead of processed.
    public var cachedTokens: Int
    public var generatedTokens: Int
    public var loadSeconds: Double
    public var promptSeconds: Double
    public var generateSeconds: Double

    public init(text: String, promptTokens: Int, cachedTokens: Int, generatedTokens: Int,
                loadSeconds: Double, promptSeconds: Double, generateSeconds: Double) {
        self.text = text; self.promptTokens = promptTokens; self.cachedTokens = cachedTokens
        self.generatedTokens = generatedTokens; self.loadSeconds = loadSeconds
        self.promptSeconds = promptSeconds; self.generateSeconds = generateSeconds
    }
}

public typealias LocalWriteRunner = @Sendable (LocalWriteRequest) async throws -> LocalWriteResult
