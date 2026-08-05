// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AudioLinkMac", targets: ["AudioLinkMac"])
    ],
    dependencies: [
        .package(path: "../../Packages/AudioLinkCore"),
        .package(path: "../../Packages/AudioLinkDSP"),
        .package(path: "../../Packages/AudioLinkRealtime"),
        .package(path: "../../Packages/AudioLinkStorage"),
        .package(path: "../../Packages/AudioLinkReporting"),
        .package(path: "../../Packages/AudioLinkPlugin"),
        .package(path: "../../Packages/AudioLinkSignalPath"),
        .package(path: "../../Packages/AudioLinkAdaptive"),
        .package(path: "../../Packages/AudioLinkSpatial"),
        .package(path: "../../Packages/AudioLinkDistributed"),
    ],
    targets: [
        .executableTarget(
            name: "AudioLinkMac",
            dependencies: [
                "AudioLinkCore",
                "AudioLinkDSP",
                "AudioLinkRealtime",
                .product(name: "AudioLinkRealtimeSupport", package: "AudioLinkRealtime"),
                "AudioLinkStorage",
                "AudioLinkReporting",
                "AudioLinkPlugin",
                "AudioLinkSignalPath",
                "AudioLinkAdaptive",
                "AudioLinkSpatial",
                "AudioLinkDistributed"
            ]
        ),
        .testTarget(
            name: "AudioLinkMacTests",
            dependencies: ["AudioLinkMac", "AudioLinkCore", "AudioLinkDSP", "AudioLinkRealtime"]
        )
    ]
)
