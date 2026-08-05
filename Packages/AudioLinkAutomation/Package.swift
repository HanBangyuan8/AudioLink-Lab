// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkAutomation",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AudioLinkAutomation", targets: ["AudioLinkAutomation"]),
        .executable(name: "audiolink", targets: ["audiolink"])
    ],
    dependencies: [
        .package(path: "../AudioLinkCore"),
        .package(path: "../AudioLinkDSP"),
        .package(path: "../AudioLinkRealtime"),
        .package(path: "../AudioLinkReporting"),
        .package(path: "../AudioLinkStorage"),
        .package(path: "../AudioLinkBundle"),
        .package(path: "../AudioLinkPlatform")
    ],
    targets: [
        .target(name: "AudioLinkAutomation", dependencies: ["AudioLinkCore", "AudioLinkDSP", "AudioLinkPlatform"], linkerSettings: [.linkedFramework("Network")]),
        .executableTarget(name: "audiolink", dependencies: ["AudioLinkAutomation", "AudioLinkCore", "AudioLinkDSP", "AudioLinkRealtime", .product(name: "AudioLinkRealtimeSupport", package: "AudioLinkRealtime"), "AudioLinkReporting", "AudioLinkStorage", "AudioLinkBundle", "AudioLinkPlatform"]),
        .testTarget(name: "AudioLinkAutomationTests", dependencies: ["AudioLinkAutomation", "AudioLinkCore", "AudioLinkDSP"])
    ]
)
