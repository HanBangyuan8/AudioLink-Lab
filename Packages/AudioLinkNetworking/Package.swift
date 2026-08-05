// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkNetworking",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AudioLinkNetworking", targets: ["AudioLinkNetworking"])
    ],
    dependencies: [
        .package(path: "../AudioLinkCore")
    ],
    targets: [
        .target(
            name: "AudioLinkNetworking",
            dependencies: ["AudioLinkCore"],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit")
            ]
        ),
        .testTarget(name: "AudioLinkNetworkingTests", dependencies: ["AudioLinkNetworking"])
    ]
)
