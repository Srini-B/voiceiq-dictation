#if os(macOS)
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import VoiceIQSpeech

/// VoiceIQ Writer on the Mac's GPU, in the speech helper. The model stays
/// loaded between dictations until `stop` or the helper's idle exit.
///
/// Measured against Python mlx-lm on the 42 bench cases
/// (`scripts/writer-model/bench`): identical prompt tokens and identical
/// greedy outputs. Caching the system-prompt prefix changed two or three of
/// those outputs (the split prefill rounds differently) to save about 0.1 s,
/// so every request prefills the whole prompt.
actor MLXWriterSession: LocalWriterSession {
    private let model: LocalWriterModel
    private var context: ModelContext?
    private var directory: URL?

    init(model: LocalWriterModel) {
        self.model = model
    }

    func write(_ request: LocalWriterRequest, directory: URL) async -> LocalWriterOutput? {
        var loadSeconds: Double?
        if context == nil || self.directory != directory {
            let started = Date()
            do {
                let loaded = try await LLMModelFactory.shared.load(from: directory, using: TokenizerLoader())
                try withError { eval(loaded.model) }
                context = loaded
                self.directory = directory
                loadSeconds = Date().timeIntervalSince(started)
            } catch {
                Log.transcription.error("Writer did not load: \(error.localizedDescription, privacy: .public)")
                await stop()
                return nil
            }
        }
        guard let context else { return nil }
        do {
            let started = Date()
            let prompt = try context.tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": LocalWriterPrompt.system], ["role": "user", "content": request.user]],
                tools: nil, additionalContext: ["enable_thinking": false]
            )
            var iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray(prompt)), model: context.model,
                parameters: GenerateParameters(maxTokens: request.maxTokens, temperature: 0)
            )
            let stops = model.stopTokens
            var generated: [Int] = []
            var firstToken: Double?
            var finished = false
            while let token = iterator.next(), !Task.isCancelled {
                if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                if stops.contains(Int32(token)) {
                    finished = true
                    break
                }
                generated.append(token)
            }
            // Out of tokens or cancelled: an unfinished rewrite would pass the
            // gate as a shortened text, so the transcript goes in instead.
            guard finished else {
                Log.transcription.error("Writer stopped before its end token after \(generated.count, privacy: .public) tokens")
                return nil
            }
            let text = context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: false)
            return LocalWriterOutput(
                text: LocalWriterPrompt.output(text), loadSeconds: loadSeconds,
                firstTokenSeconds: firstToken ?? 0, totalSeconds: Date().timeIntervalSince(started),
                promptTokens: prompt.count, generatedTokens: generated.count, memoryBytes: Memory.peakMemory
            )
        } catch {
            Log.transcription.error("Writer failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func stop() async {
        context = nil
        directory = nil
        Memory.clearCache()
    }
}

/// swift-transformers' tokenizer under MLXLMCommon's protocol. The writer's
/// folder holds `tokenizer.json`, `tokenizer_config.json` and
/// `chat_template.jinja`, which `AutoTokenizer` reads without the network.
private struct TokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
#endif
