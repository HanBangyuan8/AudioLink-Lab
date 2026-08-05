// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkStorage",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AudioLinkStorage", targets: ["AudioLinkStorage"])
    ],
    dependencies: [
        .package(path: "../AudioLinkCore")
    ],
    targets: [
        .target(name: "AudioLinkStorage", dependencies: ["AudioLinkCore"]),
        .testTarget(name: "AudioLinkStorageTests", dependencies: ["AudioLinkStorage", "AudioLinkCore"])
    ]
)

