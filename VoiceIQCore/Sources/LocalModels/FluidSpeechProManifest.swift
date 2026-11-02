import Foundation

/// Fluid Speech Pro by FluidVoice, converted to 16-bit Core ML for macOS 15 and iOS 18.
/// FluidVoice publishes it only as a NeMo checkpoint
/// (`FluidVoice-Labs/fluid-speech-pro`); it is Parakeet TDT 0.6B v3 with one
/// extra encoder block, so the converted package has Fluid Speech Mini's
/// inputs, outputs and vocabulary and FluidAudio loads it as `.v3`. The
/// conversion is `scripts/fluid-speech-pro-coreml/`.
///
/// Sizes and SHA-256 digests are of the uploaded files. 21 files,
/// 1,228,362,429 bytes. Installing it removes the retired on-device
/// Nemotron 3.5 folder.
extension LocalModelManifest {
    static let fluidSpeechPro = LocalModelManifest(
        repository: "cyron/fluid-speech-pro-coreml",
        revision: "ec52e16204b3d2c4c8bf60e576728fc58a825689",
        directoryName: "fluid-speech-pro",
        replaces: "nemotron-3.5-multilingual-2240ms",
        files: [
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "6882e6eb3ca826af5fd4392afa8558b64e2f4194f50734a9eabe6e3391dc71e5"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 617, sha256: "157322adc67cde961ad4b0a656e2d0d6a949159306e9fc9f83a298b6359dfe1b"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 3_010, sha256: "96d56da666e3c8ad9e32807b951138760ed713cd38c23c523be7b2aae1a2a54c"),
            .init(path: "Preprocessor.mlmodelc/model.mil", size: 17_484, sha256: "37b4167cdc768cd7773e80c6be9c7728a00a5db98b184bf82850a8f19824ff6c"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 982_784, sha256: "195d241d21bef3cfaf0387506f03c4c72188494a71ea82cf5ed01917b2175c63"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "54758fb19fce9bf37c0f0348f7513a52c6fa6b3ca49109239abe75ee6117d56a"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", size: 625, sha256: "6567c7097ef78eb2fc65abfd3024fac9cd363a8debcdaf8a295ca2e03d081c35"),
            .init(path: "Encoder.mlmodelc/metadata.json", size: 3_053, sha256: "0d812f0f3fde10928fb6ce6c271a452ecd92c2bcaf8ebb1047f56c48403101c4"),
            .init(path: "Encoder.mlmodelc/model.mil", size: 827_901, sha256: "1e86d2720de5b2b1bbf9592d1d79930b00b43d636319d3d251513cd9c8939611"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 1_190_096_640, sha256: "82d1453ea3a864c4423e79aee48a2f1772af9a8acfe97bddabb93d4259096a8f"),
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "67f16b357141fc813041e910bad537d3f88422be1421896d3a446a52c1904ece"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", size: 686, sha256: "21c45b622f828ec0ec5f8daac5e98c6c2c61f04ec6c29664247dc8e525a9a4e6"),
            .init(path: "Decoder.mlmodelc/metadata.json", size: 3_577, sha256: "98ee3d6095dcf4d8fd47935c29d6345ec6414bd9bf5c8d96c1f0b41e51818712"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 11_416, sha256: "2949dffdf46e39a2758c23de2754837e892968b16a19f610527026a2401cd731"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "ca377d5f7432a3019b7a9d9fb2cc4c489b87934108213adac9aba2384945b6e3"),
            .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8bbc7187c673c7f2164d19d610aeb2c22caa142f32cf7d3025a7d17fe1390013"),
            .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 718, sha256: "3a161434668d72011a832e4c455eccb6676612f4715b1faa09ec6344ba450e5c"),
            .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3_721, sha256: "55ad62fc6f8972726599ea706a909007e93035d9214a025b27fb30221125fa1f"),
            .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 10_347, sha256: "74353e2f140c69216ad81240c40b8153ff2b71878914c2a87ea1ab184414f207"),
            .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
            .init(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    )
}
