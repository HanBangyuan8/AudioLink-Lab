// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkPlatform",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AudioLinkPlatform", targets: ["AudioLinkPlatform"])],
    targets: [
        .target(name: "AudioLinkPlatform"),
        .testTarget(name: "AudioLinkPlatformTests", dependencies: ["AudioLinkPlatform"])
    ]
)
