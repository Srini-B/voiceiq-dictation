import Foundation

/// Fluid Speech Pro by FluidVoice (Core ML, `FluidVoice-Labs/fluid-speech-pro-coreml`):
/// Parakeet TDT 0.6B v3 with one extra encoder block, 8-bit encoder weights,
/// its own NeMo-exact preprocessor, and the v3 inputs, outputs and
/// vocabulary, so FluidAudio loads it as `.v3`. As with Fluid Speech Mini, the
/// repository's `JointDecision.mlmodelc` installs as `JointDecisionv3.mlmodelc`.
///
/// Sizes and SHA-256 digests come from the commit's tree metadata, made by
/// `gen_manifest.py` (LFS files carry their SHA-256; small git files were
/// downloaded and checked against their git blob SHA-1). 21 files,
/// 652,304,885 bytes. License: CC BY 4.0. Installs to
/// `<appSupport>/Models/fluid-speech-pro/<revision>`, so the stale-revision
/// cleanup removes the 16-bit conversion that builds before 0.7 downloaded.
extension LocalModelManifest {
    private static let fluidSpeechProRepository = "FluidVoice-Labs/fluid-speech-pro-coreml"
    private static let fluidSpeechProRevision = "3b9d38a93d606f84011e5a0a669b7ea146375a22"

    private static func proRemote(_ path: String) -> URL {
        huggingFaceURL(repository: fluidSpeechProRepository, revision: fluidSpeechProRevision, path: path)
    }

    static let fluidSpeechPro = LocalModelManifest(
        repository: fluidSpeechProRepository,
        revision: fluidSpeechProRevision,
        directoryName: "fluid-speech-pro",
        files: [
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "d172cb80cbf3a2cd768952557164db1b50b9c6aef16af3653d2fd7c03d9fe8e5"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", size: 491, sha256: "5059c27aa8cc44eb735247d335e18da599d15e30d67b3d2d5633679fc5806f8a"),
            .init(path: "Decoder.mlmodelc/metadata.json", size: 3_311, sha256: "47ee2ad3514945b6ee3ccd4171ed3b2318e38f3b929e4398ce33b50aca606083"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 11_823, sha256: "9d605291dfdaef07ef88b8d3dbf0702766f1ceea5649d5d6dee4d2322d8fa678"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "7b3e3a4e3fbb580ae990613915f8ea2309226d85999ae37120912b8352d1df9e"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "ac53d09c1b1f7f00fd1a07a630d57c4193089b19fe0d3b1571a3ecf91be62aa4"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", size: 427, sha256: "abfbc09cc0b8aba7911e38390390f1c5850e3665862238035052e015659ebb74"),
            .init(path: "Encoder.mlmodelc/metadata.json", size: 2_758, sha256: "cc74be4442be9fe7d6428aa238364d40e91d3c0ca4ce3cfa2f4fef4ad7a42cee"),
            .init(path: "Encoder.mlmodelc/model.mil", size: 621_903, sha256: "f71d68afe10e227c39d43af07c1aa1a88dd0eb2f63109a3e03711066e38a2e9d"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 613_088_448, sha256: "4abdc3b4af2ff9b2843105f29677f0e674d2b08638b1ce6feac60876c235c659"),
            .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3dd0d66c51f69d683c587d5c88f3256d5e1690105ecf9d8ca4b0c2b8e1c883c7", downloadURL: proRemote("JointDecision.mlmodelc/analytics/coremldata.bin")),
            .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 462, sha256: "febdb37a5ad1a119539c33cf68fac1c51f80f40f82c90b6ef312033191ff4063", downloadURL: proRemote("JointDecision.mlmodelc/coremldata.bin")),
            .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 2_728, sha256: "36fa268dd3c132c7305bbe1f17b5891a00f91caf0a883782375c35a97e2f4ada", downloadURL: proRemote("JointDecision.mlmodelc/metadata.json")),
            .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 7_178, sha256: "618bc532db01d5d80da27d0137e4b50cf2f56dde54e0686a4a1e732d74c1a55c", downloadURL: proRemote("JointDecision.mlmodelc/model.mil")),
            .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "f0939e8807dded497926a7c3634af698557ec8b155d804f8f40e367e97f90849", downloadURL: proRemote("JointDecision.mlmodelc/weights/weight.bin")),
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "886396da81b6b29d60d79d903bd5d1f00077a7a4323f40cd2e9214d4205d8e6b"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 429, sha256: "38f130eac9ffde8c684043d76e3eecdd3b6f9564d9efa59f7a87a34a272a4901"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2_606, sha256: "c25d98c19a181b7fa65ee50c34f5066f67172c22f0bf116a42b59443ee4bc37d"),
            .init(path: "Preprocessor.mlmodelc/model.mil", size: 11_891, sha256: "71d4ad016334b3ad73ea7b69b6813feefe3b81f59e0b5e924f90f088cb02a7c9"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 2_150_580, sha256: "44180071e400951080786feb46452bffc4fb26363a703655ebadb760c8ad4030"),
            .init(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    )
}
