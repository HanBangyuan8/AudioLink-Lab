// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkDSP",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AudioLinkDSP", targets: ["AudioLinkDSP"]),
        .executable(name: "AudioLinkSignalTool", targets: ["AudioLinkSignalTool"]),
        .executable(name: "AudioLinkAudioFileTool", targets: ["AudioLinkAudioFileTool"]),
        .executable(name: "AudioLinkCorrelationTool", targets: ["AudioLinkCorrelationTool"])
    ],
    dependencies: [
        .package(path: "../AudioLinkCore")
    ],
    targets: [
        .target(
            name: "AudioLinkDSP",
            dependencies: ["AudioLinkCore"],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .executableTarget(
            name: "AudioLinkSignalTool",
            dependencies: ["AudioLinkDSP", "AudioLinkCore"]
        ),
        .executableTarget(
            name: "AudioLinkAudioFileTool",
            dependencies: ["AudioLinkDSP", "AudioLinkCore"]
        ),
        .executableTarget(
            name: "AudioLinkCorrelationTool",
            dependencies: ["AudioLinkDSP", "AudioLinkCore"]
        ),
        .testTarget(name: "AudioLinkDSPTests", dependencies: ["AudioLinkDSP", "AudioLinkCore"])
    ]
)
