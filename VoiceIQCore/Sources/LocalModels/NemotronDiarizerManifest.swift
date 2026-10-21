import Foundation

/// Nemotron 3 Diarization (Core ML), the offline monolithic v2 bundle
/// FluidAudio's `Nemotron3Config.offline` loads. The bundle sits under
/// `monolithic/v2/` in the repository and the silence embedding at its root;
/// both install flat, as `Nemotron3Models.load(config:directory:)` expects.
/// 5 files, 199,162,403 bytes. Sizes and SHA-256 digests come from the
/// commit's tree metadata; the small git files were downloaded and checked
/// against their git blob SHA-1 before their SHA-256 was recorded. License:
/// OpenMDW-1.1.
extension LocalModelManifest {
    private static let diarizerRepository = "FluidInference/nemotron-3-diarization-coreml"
    private static let diarizerRevision = "25a90f97f254428d4b30374b76af9c74fdee8327"

    static let nemotronDiarizer = LocalModelManifest(
        repository: diarizerRepository,
        revision: diarizerRevision,
        remotePrefix: "monolithic/v2/",
        directoryName: "nemotron-3-diarization-offline",
        files: [
            .init(path: "Nemotron3Diarizer_offline.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "491594df92282a4f2cef65e96d236e210a5c4627063e37e822ec858aaaad416d"),
            .init(path: "Nemotron3Diarizer_offline.mlmodelc/coremldata.bin", size: 758, sha256: "8b790c919c65744648c17290a26d3371e0e55db655310e7f8445080757b0bf08"),
            .init(path: "Nemotron3Diarizer_offline.mlmodelc/model.mil", size: 505_274, sha256: "ea5673d9e9ec785e7c8fb628acd82f9f86214c46b6584eaacdb6faddcb3f0277"),
            .init(path: "Nemotron3Diarizer_offline.mlmodelc/weights/weight.bin", size: 198_654_080, sha256: "bab76e5f190d0e4a4e174e7fcb1e9beea58c6b2be56e665e2cac8fba6d10f7f1"),
            .init(path: "learnable_sil_emb.bin", size: 2_048, sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7",
                  downloadURL: huggingFaceURL(repository: diarizerRepository, revision: diarizerRevision, path: "learnable_sil_emb.bin")),
        ]
    )
}
