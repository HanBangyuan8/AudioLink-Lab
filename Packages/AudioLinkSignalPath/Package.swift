// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkSignalPath",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AudioLinkSignalPath", targets: ["AudioLinkSignalPath"])],
    dependencies: [.package(path: "../AudioLinkCore")],
    targets: [
        .target(name: "AudioLinkSignalPath", dependencies: ["AudioLinkCore"]),
        .testTarget(name: "AudioLinkSignalPathTests", dependencies: ["AudioLinkSignalPath"])
    ]
)
