#if os(iOS)
import CLlama
import Darwin
import Foundation
import VoiceIQSpeech

/// VoiceIQ Writer on iPhone and iPad: llama.cpp on the CPU, in-process. iOS
/// forbids GPU work in the background voice session, and the vendored build
/// has no Metal backend, so nothing here can reach the GPU.
///
/// The folder holds one GGUF, an exact repack of the MLX 4-bit weights
/// (`scripts/writer-model/to_gguf.py`). Through llama.cpp on the M2 CPU the
/// 2B passes 40 of the 42 bench cases and the 0.6B 35, as with MLX.
actor LlamaWriterSession: LocalWriterSession {
    private let model: LocalWriterModel
    private var weights: OpaquePointer?

    init(model: LocalWriterModel) {
        self.model = model
    }

    func write(_ request: LocalWriterRequest, directory: URL) async -> LocalWriterOutput? {
        guard !Task.isCancelled else { return nil }
        var loadSeconds: Double?
        if weights == nil {
            let started = Date()
            _ = Self.setUp
            var params = llama_model_default_params()
            params.n_gpu_layers = 0
            guard let file = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "gguf" }),
                let loaded = llama_model_load_from_file(file.path, params) else {
                Log.transcription.error("Writer did not load from \(directory.lastPathComponent, privacy: .public)")
                return nil
            }
            weights = loaded
            loadSeconds = Date().timeIntervalSince(started)
        }
        guard let weights else { return nil }
        let started = Date()
        let vocab = llama_model_get_vocab(weights)
        let prompt = Self.tokenize(LocalWriterPrompt.chat(user: request.user), vocab: vocab)
        guard !prompt.isEmpty, !Task.isCancelled else { return nil }
        // The KV cache grows with the context: about 450 MB for the 0.6B at
        // this size (the 2B's few attention layers take a tenth of that).
        // Longer dictations, over roughly 1,000 words, insert the transcript.
        guard prompt.count + request.maxTokens + 1 <= Self.maxContext else {
            Log.transcription.notice("Writer skipped: \(prompt.count) prompt + \(request.maxTokens) tokens is over \(Self.maxContext)")
            return nil
        }

        var params = llama_context_default_params()
        params.n_ctx = UInt32(prompt.count + request.maxTokens + 1)
        params.n_batch = params.n_ctx
        params.n_threads = Self.threads
        params.n_threads_batch = Self.threads
        params.offload_kqv = false
        params.op_offload = false
        guard let context = llama_init_from_model(weights, params) else { return nil }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer {
            llama_sampler_free(sampler)
            llama_free(context)
        }

        let stops = model.stopTokens
        var next = prompt
        var bytes: [CChar] = []
        var generated = 0
        var firstToken: Double?
        var finished = false
        while generated < request.maxTokens, !Task.isCancelled {
            let decoded = next.withUnsafeMutableBufferPointer {
                llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
            }
            guard decoded == 0 else { return nil }
            let token = llama_sampler_sample(sampler, context, -1)
            if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
            if stops.contains(token) || llama_vocab_is_eog(vocab, token) {
                finished = true
                break
            }
            bytes += Self.piece(token, vocab: vocab)
            generated += 1
            next = [token]
        }
        // Out of tokens or cancelled: an unfinished rewrite would pass the
        // gate as a shortened text, so the transcript goes in instead.
        guard finished else {
            Log.transcription.error("Writer stopped before its end token after \(generated, privacy: .public) tokens")
            return nil
        }
        let text = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return LocalWriterOutput(
            text: LocalWriterPrompt.output(text), loadSeconds: loadSeconds,
            firstTokenSeconds: firstToken ?? 0, totalSeconds: Date().timeIntervalSince(started),
            promptTokens: prompt.count, generatedTokens: generated, memoryBytes: ProcessFootprint.bytes
        )
    }

    func stop() async {
        if let weights { llama_model_free(weights) }
        weights = nil
    }

    private static let maxContext = 4096

    /// Once per process: the CPU backend, and llama.cpp's own logging off.
    private static let setUp: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// The performance cores: two on an iPhone, the Mac's on the Simulator.
    private static let threads: Int32 = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 else { return 2 }
        return cores
    }()

    /// Special tokens parsed, no BOS: the prompt is the rendered chat template.
    private static func tokenize(_ text: String, vocab: OpaquePointer?) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let length = Int32(utf8.count - 1)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        let count = llama_tokenize(vocab, utf8, length, &tokens, Int32(tokens.count), false, true)
        return count > 0 ? Array(tokens.prefix(Int(count))) : []
    }

    private static func piece(_ token: llama_token, vocab: OpaquePointer?) -> [CChar] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return Array(buffer.prefix(Int(max(0, count))))
    }
}
#endif
