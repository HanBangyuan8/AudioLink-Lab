// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkRealtime",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AudioLinkRealtime", targets: ["AudioLinkRealtime"]),
        .library(name: "AudioLinkRealtimeSupport", targets: ["AudioLinkRealtimeSupport"])
    ],
    dependencies: [
        .package(path: "../AudioLinkCore"),
        .package(path: "../AudioLinkDSP")
    ],
    targets: [
        .target(name: "AudioLinkRealtimeSupport", path: "Sources/AudioLinkRealtimeSupport"),
        .target(
            name: "AudioLinkRealtime",
            dependencies: ["AudioLinkCore", "AudioLinkDSP", "AudioLinkRealtimeSupport"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "AudioLinkRealtimeTests",
            dependencies: ["AudioLinkRealtime", "AudioLinkRealtimeSupport", "AudioLinkCore", "AudioLinkDSP"]
        )
    ]
)
