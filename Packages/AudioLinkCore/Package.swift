// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AudioLinkCore", targets: ["AudioLinkCore"])
    ],
    targets: [
        .target(name: "AudioLinkCore"),
        .testTarget(name: "AudioLinkCoreTests", dependencies: ["AudioLinkCore"])
    ]
)

