// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkPlugin",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AudioLinkPlugin", targets: ["AudioLinkPlugin"])],
    dependencies: [.package(path: "../AudioLinkCore")],
    targets: [
        .target(name: "AudioLinkPlugin", dependencies: ["AudioLinkCore"], linkerSettings: [.linkedFramework("AudioToolbox")]),
        .testTarget(name: "AudioLinkPluginTests", dependencies: ["AudioLinkPlugin"])
    ]
)
