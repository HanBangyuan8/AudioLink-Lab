// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkBundle",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AudioLinkBundle", targets: ["AudioLinkBundle"])],
    targets: [
        .target(name: "AudioLinkBundle"),
        .testTarget(name: "AudioLinkBundleTests", dependencies: ["AudioLinkBundle"])
    ]
)
