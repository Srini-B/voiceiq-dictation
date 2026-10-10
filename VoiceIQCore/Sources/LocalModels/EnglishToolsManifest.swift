#if os(macOS)
import Foundation

/// Subfolders of the English tools pack install folder.
public enum EnglishToolsFolder: String, CaseIterable, Sendable {
    /// Silero VAD unified 256 ms v6.2.1: speech detection.
    case vad
    /// Parakeet CTC 110M: dictionary correction for Parakeet.
    case ctc
}

/// The English tools pack: two small models from two Hugging Face repos,
/// each pinned to one commit, installed together as one verified folder at
/// `<appSupport>/Models/english-tools/<revision>/{vad,ctc}`. Bump
/// `revision` whenever any pinned file changes, so the marker check fails and
/// the old pack is cleared. Sizes and SHA-256 digests come from each commit's
/// tree metadata; the small git files were downloaded and checked against their
/// git blob SHA-1 before their SHA-256 was recorded. 17 files, 103,865,880 bytes.
///
/// v1 also carried LocalVQE noise reduction. It was dropped after a replay of
/// 15 dictations raised word error rate for both decoders (Parakeet 14.9% to
/// 21.2%, Nemotron 24.9% to 32.6%); see
/// `activities/2026-10-10-drop-speech-enhancement-and-nemotron-bias.md`.
extension LocalModelManifest {
    static let englishTools = LocalModelManifest(
        repository: "FluidInference",
        revision: "v2",
        directoryName: "english-tools",
        files: files(in: .vad, repository: "FluidInference/silero-vad-coreml", revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96", [
                ("silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin", 243, "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
                ("silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin", 625, "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
                ("silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json", 3_335, "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
                ("silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil", 176_918, "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
                ("silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin", 882_304, "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063"),
            ])
            + files(in: .ctc, repository: "FluidInference/parakeet-ctc-110m-coreml", revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa", [
                ("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3"),
                ("MelSpectrogram.mlmodelc/coremldata.bin", 330, "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c"),
                ("MelSpectrogram.mlmodelc/metadata.json", 1_962, "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3"),
                ("MelSpectrogram.mlmodelc/model.mil", 12_584, "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79"),
                ("MelSpectrogram.mlmodelc/weights/weight.bin", 567_712, "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8"),
                ("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa"),
                ("AudioEncoder.mlmodelc/coremldata.bin", 505, "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a"),
                ("AudioEncoder.mlmodelc/metadata.json", 3_456, "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2"),
                ("AudioEncoder.mlmodelc/model.mil", 1_060_924, "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e"),
                ("AudioEncoder.mlmodelc/weights/weight.bin", 100_778_304, "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd"),
                ("vocab.json", 16_086, "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f"),
                ("tokenizer.json", 360_106, "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db"),
            ])
    )

    /// Places one repo's files under `folder`, each downloaded from the pinned
    /// commit rather than the pack's own repository and revision.
    private static func files(
        in folder: EnglishToolsFolder, repository: String, revision: String,
        _ entries: [(path: String, size: Int64, sha256: String)]
    ) -> [File] {
        entries.map { entry in
            File(
                path: "\(folder.rawValue)/\(entry.path)",
                size: entry.size,
                sha256: entry.sha256,
                downloadURL: huggingFaceURL(repository: repository, revision: revision, path: entry.path)
            )
        }
    }
}
#endif
