// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "VoiceIQCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VoiceIQCore", targets: ["VoiceIQCore"]),
        // The keyboard and Live Activity extensions link only this: it is
        // extension-safe and carries no network or audio code.
        .library(name: "VoiceIQBridge", targets: ["VoiceIQBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/Clipy/Sauce.git", from: "2.2.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        // WebRTC's AEC3 echo canceller and a small C bridge, built by
        // Vendor/WebRTCAEC/build.sh. BSD-licensed; see Vendor/WebRTCAEC/Notices.
        .binaryTarget(
            name: "CVoiceIQAEC",
            path: "Vendor/WebRTCAEC/CVoiceIQAEC.xcframework"
        ),
        // Catches Objective-C exceptions that Swift cannot (AVFAudio raises
        // them while the input device is changing).
        .target(
            name: "VoiceIQObjC",
            path: "ObjCSupport"
        ),
        .target(
            name: "VoiceIQCore",
            dependencies: [
                "VoiceIQObjC",
                "VoiceIQBridge",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sauce", package: "Sauce", condition: .when(platforms: [.macOS])),
                // The vendored xcframework carries a macOS slice only. iOS
                // meetings record the mic alone, so there is no echo to cancel.
                .target(name: "CVoiceIQAEC", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources",
            exclude: ["Bridge"],
            linkerSettings: [
                .linkedLibrary("c++", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "VoiceIQBridge",
            path: "Sources/Bridge"
        ),
        .testTarget(
            name: "VoiceIQCoreTests",
            dependencies: ["VoiceIQCore"],
            path: "Tests"
        ),
    ]
)
