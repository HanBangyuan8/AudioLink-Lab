// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkMobile",
    platforms: [
        .iOS(.v16),
        // The macOS fallback lets CI compile the shared state machine without
        // pretending that AVAudioSession is available on macOS.
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AudioLinkMobile", targets: ["AudioLinkMobile"])
    ],
    dependencies: [
        .package(path: "../../Packages/AudioLinkCore"),
        .package(path: "../../Packages/AudioLinkDSP"),
        .package(path: "../../Packages/AudioLinkNetworking"),
        .package(path: "../../Packages/AudioLinkRealtime"),
    ],
    targets: [
        .executableTarget(
            name: "AudioLinkMobile",
            dependencies: ["AudioLinkCore", "AudioLinkDSP", "AudioLinkNetworking", .product(name: "AudioLinkRealtimeSupport", package: "AudioLinkRealtime")],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS]))
            ]
        ),
        .testTarget(
            name: "AudioLinkMobileTests",
            dependencies: ["AudioLinkMobile", "AudioLinkCore", "AudioLinkDSP", "AudioLinkNetworking"]
        )
    ]
)
