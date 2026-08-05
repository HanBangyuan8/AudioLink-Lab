// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkSpatial",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AudioLinkSpatial", targets: ["AudioLinkSpatial"])],
    dependencies: [
        .package(path: "../AudioLinkCore"),
        .package(path: "../AudioLinkDSP")
    ],
    targets: [
        .target(name: "AudioLinkSpatial", dependencies: ["AudioLinkCore", "AudioLinkDSP"]),
        .testTarget(name: "AudioLinkSpatialTests", dependencies: ["AudioLinkSpatial", "AudioLinkCore"])
    ]
)
