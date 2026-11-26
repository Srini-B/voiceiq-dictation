// swift-tools-version: 6.0
import PackageDescription

// Runs prepared meetings through VoiceiQ's own meeting code: Gemini for the
// words, the on-device speaker model for the far side, the screen and
// calendar names, and the notes request. See README.md.
let package = Package(
    name: "MeetingsEval",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../VoiceIQCore")],
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
    ]
)
