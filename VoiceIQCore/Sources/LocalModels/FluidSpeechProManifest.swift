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
        revision: "42d66fdd64541b88cf70223701f59e76b766567c",
        directoryName: "fluid-speech-pro",
        replaces: "nemotron-3.5-multilingual-2240ms",
        // The 53f490b conversion. 42d66fd changes only the decoder and joint weights.
        previousRevisions: ["ec52e16204b3d2c4c8bf60e576728fc58a825689"],
        files: [
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "7fddbb840456b993e087ab904b5a3556af7bc46fe3c84fccb44f70b0ad7d1ca6"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 617, sha256: "5cd9f6187cfbd8829729868ea78ab191a24a00ee4b9279fa407a17c14211fc0a"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 3_010, sha256: "5a15a9748b72d5c33d91504f0b18d5b63ead5104f3253dcc1526586bb9daa611"),
            .init(path: "Preprocessor.mlmodelc/model.mil", size: 17_484, sha256: "37b4167cdc768cd7773e80c6be9c7728a00a5db98b184bf82850a8f19824ff6c"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 982_784, sha256: "195d241d21bef3cfaf0387506f03c4c72188494a71ea82cf5ed01917b2175c63"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "f70d85b9f7ed1712bbcf2eadb11ffe92a7121ff1820ba14b7e5592e6651df1aa"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", size: 625, sha256: "8fba0913e037325f3ac5b3693c8eb249978b84138f589cdafb2bc90637b0e64f"),
            .init(path: "Encoder.mlmodelc/metadata.json", size: 3_053, sha256: "b9bcb48373199735801076a8ce5d411f79123b6c7fba2f199ed700385a3f0895"),
            .init(path: "Encoder.mlmodelc/model.mil", size: 827_901, sha256: "1e86d2720de5b2b1bbf9592d1d79930b00b43d636319d3d251513cd9c8939611"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 1_190_096_640, sha256: "82d1453ea3a864c4423e79aee48a2f1772af9a8acfe97bddabb93d4259096a8f"),
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "5a5cb4e40cb1acb3396302a283b8a0e1126736d31904ac4fe8c33e2fe475b84f"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", size: 686, sha256: "8badc6612c0caaf79423a7d520d2c6d1fa8af0d8b4c132a86b8d4be4469cdacb"),
            .init(path: "Decoder.mlmodelc/metadata.json", size: 3_577, sha256: "41250900f27a828efa11402f1bf00f7a3f3cb2703630e263790568276e93e670"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 11_416, sha256: "2949dffdf46e39a2758c23de2754837e892968b16a19f610527026a2401cd731"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "7b3e3a4e3fbb580ae990613915f8ea2309226d85999ae37120912b8352d1df9e"),
            .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "ee28e65c1237157191306b57c708f9cef512ac0ecdd5a408facc98f0ef5de510"),
            .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 718, sha256: "66389900e7c5e63a839d2340dbac2afb88198f27b1d671d85adf765e801e3be3"),
            .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3_721, sha256: "bbb40e06589f21ecae742d2f1964fc9ce9fd17dd6161f2e71ee19aec134bfdfd"),
            .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 10_347, sha256: "74353e2f140c69216ad81240c40b8153ff2b71878914c2a87ea1ab184414f207"),
            .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "f0939e8807dded497926a7c3634af698557ec8b155d804f8f40e367e97f90849"),
            .init(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    )
}
