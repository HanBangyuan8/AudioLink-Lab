// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkAdaptive",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AudioLinkAdaptive", targets: ["AudioLinkAdaptive"])],
    dependencies: [
        .package(path: "../AudioLinkCore"),
        .package(path: "../AudioLinkDSP")
    ],
    targets: [
        .target(name: "AudioLinkAdaptive", dependencies: ["AudioLinkCore", "AudioLinkDSP"]),
        .testTarget(name: "AudioLinkAdaptiveTests", dependencies: ["AudioLinkAdaptive", "AudioLinkCore", "AudioLinkDSP"])
    ]
)
