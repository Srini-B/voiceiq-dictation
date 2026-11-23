import CoreML

/// Compute units for the models a dictation loads while the user waits.
///
/// The Neural Engine's prepared program for an encoder is held by the ANE
/// driver, not by the `e5bundlecache` on disk: a byte-identical restore of
/// that cache still gives a cold load, and on iOS the program is dropped after
/// hours of idle. Rebuilding it costs 13 s (M2) to 60 s (iPhone, iOS 27) per
/// encoder. On the CPU, Parakeet's encoder loads in 3 s cold and the CTC
/// encoder in 2 s; both reload in 0.2 s, and inference stays well under a
/// second for a dictation (scratch tool `.amp/in/scratch/coldload`,
/// 2026-10-26). Meetings (`LocalMeetingJob`) keep the ANE: they run for an
/// hour, so the compile is paid once and the ANE saves power.
enum DictationCompute {
    static let encoderUnits: MLComputeUnits = .cpuOnly

    /// For the load log.
    static var encoderLabel: String {
        switch encoderUnits {
        case .cpuOnly: "cpu"
        case .cpuAndGPU: "cpu+gpu"
        case .cpuAndNeuralEngine: "cpu+ane"
        case .all: "all"
        @unknown default: "unknown"
        }
    }
}
