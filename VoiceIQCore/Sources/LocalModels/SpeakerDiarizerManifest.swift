import Foundation

/// pyannote community-1 speaker diarization (Core ML): segmentation, the
/// FBank frontend, the WeSpeaker embedding and the PLDA projection that
/// FluidAudio's `OfflineDiarizerManager` runs, with the PLDA parameters VBx
/// clustering reads. The revision is the one FluidAudio 0.18.2 pins for this
/// repository. The files sit at the repository root and install flat, as
/// `LocalMeetingJob` loads them. 21 files, 21,599,417 bytes. Sizes and
/// SHA-256 digests come from the commit's tree metadata; the small git files
/// were downloaded and checked against their git blob SHA-1 before their
/// SHA-256 was recorded. License: CC-BY-4.0 (the repository's NOTICE.md).
extension LocalModelManifest {
    static let speakerDiarizer = LocalModelManifest(
        repository: "FluidInference/speaker-diarization-coreml",
        revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        directoryName: "speaker-diarization-community-1",
        replaces: "nemotron-3-diarization-offline",
        files: [
            .init(path: "Segmentation.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
            .init(path: "Segmentation.mlmodelc/coremldata.bin", size: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
            .init(path: "Segmentation.mlmodelc/metadata.json", size: 3_410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
            .init(path: "Segmentation.mlmodelc/model.mil", size: 43_063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
            .init(path: "Segmentation.mlmodelc/weights/weight.bin", size: 5_959_360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
            .init(path: "FBank.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
            .init(path: "FBank.mlmodelc/coremldata.bin", size: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
            .init(path: "FBank.mlmodelc/metadata.json", size: 3_409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
            .init(path: "FBank.mlmodelc/model.mil", size: 15_667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
            .init(path: "FBank.mlmodelc/weights/weight.bin", size: 1_776_896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
            .init(path: "Embedding.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
            .init(path: "Embedding.mlmodelc/coremldata.bin", size: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
            .init(path: "Embedding.mlmodelc/metadata.json", size: 2_818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
            .init(path: "Embedding.mlmodelc/model.mil", size: 78_432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
            .init(path: "Embedding.mlmodelc/weights/weight.bin", size: 13_412_288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
            .init(path: "PldaRho.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
            .init(path: "PldaRho.mlmodelc/coremldata.bin", size: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
            .init(path: "PldaRho.mlmodelc/metadata.json", size: 2_749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
            .init(path: "PldaRho.mlmodelc/model.mil", size: 7_613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
            .init(path: "PldaRho.mlmodelc/weights/weight.bin", size: 200_192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
            .init(path: "plda-parameters.json", size: 89_416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
        ]
    )
}
