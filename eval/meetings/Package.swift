// swift-tools-version: 6.2
import PackageDescription

// MeetingsEval runs prepared meetings through VoiceiQ's own meeting code:
// AssemblyAI STT-3.7 for the words, the on-device speaker model for the far side, the
// screen and calendar names, and the notes request. LocalMeetingsEval runs
// them fully on device, as the app does and through a port of Hex's offline
// pass, and makes no network call beyond the model downloads. See README.md.
let package = Package(
    name: "MeetingsEval",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../VoiceIQCore"),
        // The version and trait VoiceIQCore pins.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: ["Diarizer"]),
    ],
    targets: [
        .executableTarget(
            name: "MeetingsEval",
            dependencies: [
                .product(name: "VoiceIQCore", package: "VoiceIQCore"),
                .product(name: "VoiceIQInference", package: "VoiceIQCore"),
                .product(name: "VoiceIQSpeech", package: "VoiceIQCore"),
            ],
            path: "Sources/MeetingsEval"
        ),
        .executableTarget(
            name: "LocalMeetingsEval",
            dependencies: [
                .product(name: "VoiceIQCore", package: "VoiceIQCore"),
                .product(name: "VoiceIQInference", package: "VoiceIQCore"),
                .product(name: "VoiceIQSpeech", package: "VoiceIQCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LocalMeetingsEval"
        ),
    ]
)
