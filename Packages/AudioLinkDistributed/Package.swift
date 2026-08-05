// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkDistributed",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AudioLinkDistributed", targets: ["AudioLinkDistributed"])],
    dependencies: [
        .package(path: "../AudioLinkCore"),
        .package(path: "../AudioLinkNetworking")
    ],
    targets: [
        .target(name: "AudioLinkDistributed", dependencies: ["AudioLinkCore", "AudioLinkNetworking"]),
        .testTarget(name: "AudioLinkDistributedTests", dependencies: ["AudioLinkDistributed", "AudioLinkNetworking"])
    ]
)
