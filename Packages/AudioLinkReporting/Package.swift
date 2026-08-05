// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioLinkReporting",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AudioLinkReporting", targets: ["AudioLinkReporting"]),
        .executable(name: "AudioLinkReportTool", targets: ["AudioLinkReportTool"])
    ],
    dependencies: [
        .package(path: "../AudioLinkCore"),
        .package(path: "../AudioLinkStorage")
    ],
    targets: [
        .target(
            name: "AudioLinkReporting",
            dependencies: ["AudioLinkCore", "AudioLinkStorage"],
            linkerSettings: [
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
                .linkedFramework("CoreText", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("PDFKit", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "AudioLinkReportTool",
            dependencies: ["AudioLinkReporting", "AudioLinkCore", "AudioLinkStorage"]
        ),
        .testTarget(
            name: "AudioLinkReportingTests",
            dependencies: ["AudioLinkReporting", "AudioLinkCore", "AudioLinkStorage"]
        )
    ]
)
