import Foundation

/// Nemotron 3.5 ASR Streaming Multilingual 0.6B (Core ML), the 2240 ms chunk
/// variant. Only the `multilingual/2240ms` folder is downloaded; paths here are
/// relative to it. 22 files, 664,846,846 bytes. LFS digests come from the
/// commit's tree metadata; the small git files were downloaded and checked
/// against their git blob SHA-1 before their SHA-256 was recorded.
extension LocalModelManifest {
    static let nemotron = LocalModelManifest(
        repository: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
        revision: "1a41b75758b0337ff67db7d5408280aaaf23074e",
        remotePrefix: "multilingual/2240ms/",
        directoryName: "nemotron-3.5-multilingual-2240ms",
        files: [
            .init(path: "decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "fdb14a08e42b4806a2d1505501586be71e4f04ca9256c719544fd7ed6937e509"),
            .init(path: "decoder.mlmodelc/coremldata.bin", size: 433, sha256: "3a89047b6f74ee3d0a74c72f8c8e5016d76d9487d030f0661fe80220b441a6fd"),
            .init(path: "decoder.mlmodelc/model.mil", size: 11_743, sha256: "f3ed3e9cac9b70e1b00df48b53868dbd3c4dd8cf158af79ded0d05a96e0bf5dc"),
            .init(path: "decoder.mlmodelc/weights/weight.bin", size: 29_870_592, sha256: "dcdeccd4ccf46e2675224f9f030d46c1a89e2bda4abb316e901e1a21f1597f8f"),
            .init(path: "decoder_joint.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8a8e98a54ed1f16c3d5125816a002b991e167d620beb8fcc557f26d9a1c092f8"),
            .init(path: "decoder_joint.mlmodelc/coremldata.bin", size: 454, sha256: "6404b542fb5d5faa79648fc96a79a0b981cbd087df0378adefd1f45ae56dd86e"),
            .init(path: "decoder_joint.mlmodelc/model.mil", size: 15_801, sha256: "62144df8c1928d571c1df508a576f2d574a6bd6b1f2dba7f3f15cf9605805d6a"),
            .init(path: "decoder_joint.mlmodelc/weights/weight.bin", size: 48_782_272, sha256: "01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b"),
            .init(path: "encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "af569fd95237bdf8b91d38094691bfc990fcf3534316fa615bac5964c02809e4"),
            .init(path: "encoder.mlmodelc/coremldata.bin", size: 573, sha256: "d5471a4edf55ce02dab51e5d01c86b419a7659bcdd6aac216ba6f0b795eae8bf"),
            .init(path: "encoder.mlmodelc/model.mil", size: 1_010_788, sha256: "3ee65463908bbc06c92691ea9172499aea3f7ae4ba619d39783c4a639936fae5"),
            .init(path: "encoder.mlmodelc/weights/weight.bin", size: 565_336_640, sha256: "2e00be98049a22e095452c020f183d2b23728e145cc814ba031436931b4f2e8f"),
            .init(path: "joint.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "a1a90a7d5f8b86f564a42ab45b42a43eb0bbce6682176916bd94591b28cca447"),
            .init(path: "joint.mlmodelc/coremldata.bin", size: 341, sha256: "8f750980da8ea3397d860f69e0755d3adf61ee763d7f189405d50d4e2d9f8ca0"),
            .init(path: "joint.mlmodelc/model.mil", size: 5_072, sha256: "521da827005ddcf3fbd439d12f85c34b1273642635b39a87bfbc931131cd3bf6"),
            .init(path: "joint.mlmodelc/weights/weight.bin", size: 18_911_744, sha256: "c0ef0a3a6598f962d2aad598dc6850e4428874033419817121e11f1fff4a9cfe"),
            .init(path: "metadata.json", size: 3_005, sha256: "070ae181941003ff3e7d7ff8e5c5d47aebd026e8458549cef0c9a6803dbec004"),
            .init(path: "preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "e918fd75105ef01a971d29b5ec28f531467b42dd60978c29afb1914c4af838af"),
            .init(path: "preprocessor.mlmodelc/coremldata.bin", size: 371, sha256: "3d1aa8c8e7e283e4944af4b0b701db760ed99ef14919d3f989c599b9f63335a2"),
            .init(path: "preprocessor.mlmodelc/model.mil", size: 18_449, sha256: "12637d7ddfabea2d58e6b7986699c1be7fe970dc589eeac52fcb9ad25ae06ec9"),
            .init(path: "preprocessor.mlmodelc/weights/weight.bin", size: 592_384, sha256: "297514e2b211d14b0e53cb97193d679bb89ead98d28e578f3f1d049ddbcc36b3"),
            .init(path: "tokenizer.json", size: 284_969, sha256: "fb70c8fcb6472cda2bdb799b156a8941e72762344a7c636d3b1275f1d53c4a6b"),
        ]
    )
}
