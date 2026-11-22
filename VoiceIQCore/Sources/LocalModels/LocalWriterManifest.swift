import Foundation
import VoiceIQSpeech

/// LFM3-Omni-2B by Liquid AI, quantized to Q4_K_M (GGUF), for writing
/// on-device transcripts by the writing rules and for meeting notes. Only the
/// language model: the audio and vision projector is not needed for text.
/// License: LFM Open License v1.0 (free for personal and non-commercial
/// use; commercial use only below US$10M annual revenue).
extension LocalModelManifest {
    static let writer = LocalModelManifest(
        repository: "LiquidAI/LFM3-Omni-2B-GGUF",
        revision: "d508b88f08a5b4286f2d2805a6a8d69a0ff44c72",
        directoryName: "lfm3-omni-2b",
        files: [
            .init(path: LocalWriterSupport.modelFile, size: 1_099_630_080,
                  sha256: "9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2"),
        ]
    )
}

public enum LocalWriterSupport {
    static let modelFile = "LFM3-Omni-2B-Q4_K_M.gguf"
    public static let displayName = "LFM3-Omni-2B (Liquid AI)"

    /// The Mac offers the writer. iPhone and iPad offer it with 6 GB of
    /// memory or more (iOS reports about 5.5 GiB for those), like Fluid
    /// Speech Pro: below that a 1.1 GB model next to the app risks iOS
    /// ending VoiceiQ while it writes. They also need the dot-product
    /// instructions the iOS runtime is built for (A13 and later), which
    /// leaves out the 6 GB iPad Pros with an A12X or A12Z.
    public static var isAvailable: Bool {
        guard LocalModelSupport.isAvailable else { return false }
        #if os(iOS)
        var dotProduct: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let known = sysctlbyname("hw.optional.arm.FEAT_DotProd", &dotProduct, &size, nil, 0) == 0
        return known && dotProduct == 1 && isOffered(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        #else
        return true
        #endif
    }

    public static func isOffered(physicalMemory: UInt64) -> Bool {
        LocalSpeechModel.suggested(physicalMemory: physicalMemory) == .fluidSpeechPro
    }
}
