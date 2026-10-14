#if os(macOS)
import Foundation

/// Fluid Speech Mini by FluidVoice (Core ML), an English fine-tune of Parakeet
/// TDT 0.6B v3 with the same inputs, outputs and vocabulary, so FluidAudio
/// loads it as `.v3`. Its joint network has no top-K outputs, which only
/// disables FluidAudio's English script filter. FluidAudio 0.17.7 looks for
/// the v3 joint at `JointDecisionv3.mlmodelc`, so the repository's
/// `JointDecision.mlmodelc` installs under that name.
///
/// Sizes and SHA-256 digests come from the commit's tree metadata: LFS files
/// carry their SHA-256 there; the small git files were downloaded and checked
/// against their git blob SHA-1 before their SHA-256 was recorded. Installs to
/// `<appSupport>/Models/parakeet-v3/<revision>`; keeping the folder name lets
/// the stale-revision cleanup remove an earlier Parakeet v3 download.
extension LocalModelManifest {
    private static let fluidSpeechMiniRepository = "FluidVoice-Labs/fluid-speech-mini-coreml"
    private static let fluidSpeechMiniRevision = "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a"

    private static func remote(_ path: String) -> URL {
        huggingFaceURL(repository: fluidSpeechMiniRepository, revision: fluidSpeechMiniRevision, path: path)
    }

    static let parakeet = LocalModelManifest(
        repository: fluidSpeechMiniRepository,
        revision: fluidSpeechMiniRevision,
        directoryName: "parakeet-v3",
        files: [
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2_841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            .init(path: "Preprocessor.mlmodelc/model.mil", size: 28_181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3a3caa2c6aec983d94a5659eff09a00f77077147ea6726b8ddfdf022f0238ce9"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", size: 427, sha256: "494d8e2ce30b37bcdf494b3ba7ddf6e1bc921b9a59e369a9efd44d013ca3bf7d"),
            .init(path: "Encoder.mlmodelc/metadata.json", size: 2_906, sha256: "1a2229e2cc4c271e4876715c9e36aef18bc7287e35690022c7f3939d85260ea9"),
            .init(path: "Encoder.mlmodelc/model.mil", size: 712_643, sha256: "f96b7707936ea7ce5517c5b0f5c15cc634006bc58af1fe2587ac5979dd180343"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 233_096_704, sha256: "cf0b61022de8c698984a8c7185c2d093fa744694621881ff062c46fee2546131"),
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "d4beee43a6eab29b2adcc298f2e8582e8fb79d5fe3aa9f1ab692ade681ca369d"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", size: 491, sha256: "6094d06d05c1ca4599c7b13c9a4ca7c00826ee2396796cf3084ce602a9884468"),
            .init(path: "Decoder.mlmodelc/metadata.json", size: 3_373, sha256: "13fcb358af8b028703dc7f424fd149ce9524642de510f3d682b75d471b1a001d"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 13_411, sha256: "4ccd8ecbc7eb59bed7ad38d471bf6b78ef52a24500bf64619c549ed45fbee4e9"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 11_845_120, sha256: "d173e381488d07fd7648e2ccecbfb1bceff0457d75461550b26ba7fa2d23309a"),
            .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "9e767d69e1092b27b28d9f236b9cbcded58ff3891e320cba7855e2c24e803d69", downloadURL: remote("JointDecision.mlmodelc/analytics/coremldata.bin")),
            .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 462, sha256: "284b235c08cd4769202af017f854deace69c0209c29f2253a2073bb68d58d38d", downloadURL: remote("JointDecision.mlmodelc/coremldata.bin")),
            .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 2_790, sha256: "fe1ce083f9ff57524926a92fc264b0cf7d88f3ba9852f7acf9f59dcdf427e01f", downloadURL: remote("JointDecision.mlmodelc/metadata.json")),
            .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 7_547, sha256: "1109ce72f6d014a6b99e49b41e83b3082d7555d74a6275838e7cbea42a6bd0ee", downloadURL: remote("JointDecision.mlmodelc/model.mil")),
            .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 6_350_284, sha256: "f991f65979c1b3fee3db39a645aa87e6bef1a304ed1816d074b17479bea797fc", downloadURL: remote("JointDecision.mlmodelc/weights/weight.bin")),
            .init(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    )
}
#endif
