// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/AudioLinkCore"),
        .package(path: "../../Packages/AudioLinkDSP"),
        .package(path: "../../Packages/AudioLinkStorage"),
        .package(path: "../../Packages/AudioLinkNetworking"),
        .package(path: "../../Packages/AudioLinkReporting")
    ],
    targets: [
        .executableTarget(
            name: "AudioLinkBenchmarks",
            dependencies: [
                "AudioLinkCore", "AudioLinkDSP", "AudioLinkStorage",
                "AudioLinkNetworking", "AudioLinkReporting"
            ]
        )
    ]
)
