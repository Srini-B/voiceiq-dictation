import Foundation
import llama
import VoiceIQSpeech

/// One LFM3-Omni-2B generation through llama.cpp. The model and its context
/// live only inside `run`: both are freed before it returns, whatever
/// happens, so the writer never holds memory between dictations or next to
/// the speech models.
enum LocalWriterJob {
    enum Failure: LocalizedError {
        case load, context, prompt(Int32), decode(Int32), grammar, cancelled
        var errorDescription: String? {
            switch self {
            case .load: return "The on-device writer could not load its model."
            case .context: return "The on-device writer could not start."
            case .prompt(let code): return "The on-device writer could not read the text (\(code))."
            case .decode(let code): return "The on-device writer stopped while writing (\(code))."
            case .grammar: return "The on-device writer's answer format is invalid."
            case .cancelled: return "Cancelled."
            }
        }
    }

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    static func run(_ request: LocalWriteRequest, isCancelled: () -> Bool) throws -> LocalWriteResult {
        _ = backend
        let started = Date()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = request.useGPU ? -1 : 0
        // Repacking copies the weights into anonymous memory for faster CPU
        // kernels; mapped from the file they stay reclaimable instead.
        modelParams.use_extra_bufts = false
        guard let model = llama_model_load_from_file(request.model.path, modelParams) else { throw Failure.load }
        defer { llama_model_free(model) }
        let vocab = llama_model_get_vocab(model)

        // LFM3's chat format, with thinking off as its template renders it.
        let prefix = tokens(vocab, "<|startoftext|><|im_start|>system\n\(request.system)<|im_end|>\n")
        let rest = tokens(vocab, "<|im_start|>user\n\(request.user)<|im_end|>\n<|im_start|>assistant\n<think></think>")
        let promptCount = prefix.count + rest.count
        guard promptCount + request.maxTokens <= request.maxContext else { throw Failure.prompt(-1) }

        var contextParams = llama_context_default_params()
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        contextParams.n_ctx = UInt32((promptCount + request.maxTokens + 255) / 256 * 256)
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else { throw Failure.context }
        defer { llama_free(context) }
        let loaded = Date()

        var position: Int32 = 0
        var cached = 0
        if let cache = request.prefixCache, restore(context, from: cache, expecting: prefix) {
            cached = prefix.count
            position = Int32(prefix.count)
        } else {
            try process(context, prefix, from: &position, lastLogits: false, isCancelled: isCancelled)
            if let cache = request.prefixCache {
                try? FileManager.default.removeItem(at: cache)
                _ = prefix.withUnsafeBufferPointer {
                    llama_state_seq_save_file(context, cache.path, 0, $0.baseAddress, $0.count)
                }
            }
        }
        try process(context, rest, from: &position, lastLogits: true, isCancelled: isCancelled)
        let prompted = Date()

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if let grammar = request.grammar {
            guard let constrained = llama_sampler_init_grammar(vocab, grammar, "root") else { throw Failure.grammar }
            llama_sampler_chain_add(sampler, constrained)
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var bytes: [UInt8] = []
        var generated = 0
        while generated < request.maxTokens {
            if isCancelled() { throw Failure.cancelled }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(vocab, token)
            generated += 1
            try process(context, [token], from: &position, lastLogits: true, isCancelled: isCancelled)
        }
        let finished = Date()
        return LocalWriteResult(
            text: String(decoding: bytes, as: UTF8.self), promptTokens: promptCount, cachedTokens: cached,
            generatedTokens: generated, loadSeconds: loaded.timeIntervalSince(started),
            promptSeconds: prompted.timeIntervalSince(loaded), generateSeconds: finished.timeIntervalSince(prompted))
    }

    private static func tokens(_ vocab: OpaquePointer?, _ text: String) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var out = [llama_token](repeating: 0, count: Int(length) + 8)
        let count = llama_tokenize(vocab, text, length, &out, Int32(out.count), false, true)
        return Array(out.prefix(Int(max(0, count))))
    }

    private static func piece(_ vocab: OpaquePointer?, _ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, count))).map { UInt8(bitPattern: $0) }
    }

    /// Feeds `input` in batches from `position`; only the last token of the
    /// last batch asks for logits, when `lastLogits` is set.
    private static func process(_ context: OpaquePointer, _ input: [llama_token], from position: inout Int32,
                                lastLogits: Bool, isCancelled: () -> Bool) throws {
        guard let batch = llama_batch_ext_init(context) else { throw Failure.context }
        defer { llama_batch_ext_free(batch) }
        let size = Int(llama_n_batch(context))
        for start in stride(from: 0, to: input.count, by: size) {
            if isCancelled() { throw Failure.cancelled }
            llama_batch_ext_clear(batch)
            let end = min(start + size, input.count)
            for index in start..<end {
                let slot = llama_batch_ext_add_token(batch, 0, input[index])
                guard slot >= 0 else { throw Failure.prompt(slot) }
                var pos = position + Int32(index - start)
                _ = llama_batch_ext_set_pos(batch, slot, &pos)
                _ = llama_batch_ext_set_output_logits(batch, slot, lastLogits && index == input.count - 1)
            }
            let code = llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch)
            guard code == 0 else { throw Failure.decode(code) }
            position += Int32(end - start)
        }
    }

    /// Reads the saved system prefix back, when it was saved for exactly
    /// these tokens. A stale or damaged file is ignored and rewritten.
    private static func restore(_ context: OpaquePointer, from cache: URL, expecting prefix: [llama_token]) -> Bool {
        guard FileManager.default.fileExists(atPath: cache.path) else { return false }
        var stored = [llama_token](repeating: 0, count: prefix.count + 1)
        var count = 0
        let size = llama_state_seq_load_file(context, cache.path, 0, &stored, stored.count, &count)
        guard size > 0, count == prefix.count, Array(stored.prefix(count)) == prefix else {
            llama_memory_clear(llama_get_memory(context), true)
            return false
        }
        return true
    }
}
