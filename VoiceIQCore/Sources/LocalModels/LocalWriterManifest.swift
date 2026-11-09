import Foundation
import VoiceIQSpeech

/// VoiceIQ Writer's files, pinned to the public Hugging Face repositories
/// (docs/WRITER_MODEL.md). The Mac loads the MLX 4-bit weights; iPhone and
/// iPad load a GGUF of the same weights, repacked exactly as Q4_1
/// (`scripts/writer-model/to_gguf.py`, llama.cpp b12198). The previous
/// revisions learned the default rules only; one on disk keeps writing, without
/// the user's rules and spelling, until its update is installed.
public extension LocalWriterModel {
    var manifest: LocalModelManifest {
        switch self {
        case .qwen3_5_2b:
            #if os(macOS)
            return .writer2BMLX
            #else
            return .writer2BGGUF
            #endif
        case .qwen3_0_6b: return .writer06BGGUF
        }
    }
}

extension LocalModelManifest {
    /// 6 files, 1,079,466,957 bytes.
    static let writer2BMLX = LocalModelManifest(
        repository: "cyron/voiceiq-writer-qwen3_5-2b",
        revision: "f9e2204333dfcd43432e983f8cd3f221150f72c9",
        directoryName: "voiceiq-writer-2b-mlx",
        previousRevisions: ["0efe70d13ec7981acd39e36a537d2e628bd36dbb"],
        files: [
            .init(path: "chat_template.jinja", size: 7_755, sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
            .init(path: "config.json", size: 2_625, sha256: "8893a91e9b7763d7b94c6db181f5b7c79c6f4881a69cefb11549eefcab1823bf"),
            .init(path: "model.safetensors", size: 1_059_404_951, sha256: "bb4b716f1a4499436ffed09f51cd7cce54ebda53a86b3d1b22e6c5aef15db300"),
            .init(path: "model.safetensors.index.json", size: 60_786, sha256: "3b2dffa510d1d73decdbc12d5e1bc7d6a9f7b2deb631bfd84238a1f8fc4e0fd1"),
            .init(path: "tokenizer.json", size: 19_989_339, sha256: "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
            .init(path: "tokenizer_config.json", size: 1_501, sha256: "86f01837a638275f2d3479804e79802aaff0e3ccef15e5f29dd6afbe6551daed"),
        ]
    )

    /// The GGUF carries its own tokenizer and template.
    static let writer2BGGUF = LocalModelManifest(
        repository: "cyron/voiceiq-writer-qwen3_5-2b",
        revision: "f9e2204333dfcd43432e983f8cd3f221150f72c9",
        directoryName: "voiceiq-writer-2b-gguf",
        previousRevisions: ["683b58638ad4ace63de63b28ca716690dbf42a00"],
        files: [
            .init(path: "voiceiq-writer-qwen3_5-2b-q4_1.gguf", size: 1_188_953_728, sha256: "e0fd995b16009c618f5f728c3e579c3f0931a5e0b26933094d23a1d38f87d118"),
        ]
    )

    static let writer06BGGUF = LocalModelManifest(
        repository: "cyron/voiceiq-writer-qwen3-0_6b",
        revision: "ad95a957445c6dcfd9bd515dda4f73140e64924b",
        directoryName: "voiceiq-writer-0_6b-gguf",
        previousRevisions: ["4dafcd49fed095730bffb162aeba3482a1c14b8e"],
        files: [
            .init(path: "voiceiq-writer-qwen3-0_6b-q4_1.gguf", size: 378_703_712, sha256: "ccc1612f122d44b7da6ce1a677a78536d3b300f7c6516dc70f80278b1c9022c5"),
        ]
    )
}
