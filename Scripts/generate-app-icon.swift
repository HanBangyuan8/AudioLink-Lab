#!/usr/bin/env swift
import AppKit
import Foundation

// Keep this generator in sync with the sibling macOS repositories: the
// iconset variants, preview PNG, and ICNS chunk layout are intentionally the
// same so Finder and the DMG have identical rendering behaviour.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let output = resources.appendingPathComponent("AppIcon.icns")
let readmePreview = resources.appendingPathComponent("AppIcon.png")
let fileManager = FileManager.default

try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func writeIcon(size: Int, name: String) throws {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate bitmap \(name)"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let iconMargin = CGFloat(size) * (96.0 / 1024.0)
    let corner = CGFloat(size) * 0.19
    let bodyRect = rect.insetBy(dx: iconMargin, dy: iconMargin)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: corner, yRadius: corner)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.55, blue: 0.66, alpha: 1),
        NSColor(calibratedRed: 0.23, green: 0.37, blue: 0.94, alpha: 1)
    ])?.draw(in: body, angle: 135)

    NSColor.white.withAlphaComponent(0.20).setStroke()
    body.lineWidth = max(1, CGFloat(size) * 0.012)
    body.stroke()

    let waveRect = bodyRect.insetBy(dx: CGFloat(size) * 0.17, dy: CGFloat(size) * 0.20)
    let centerY = waveRect.midY + waveRect.height * 0.03
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: waveRect.minX, y: centerY))
    let points: [(CGFloat, CGFloat)] = [
        (0.00, 0.00), (0.13, 0.30), (0.25, -0.30), (0.38, 0.38),
        (0.51, -0.38), (0.64, 0.27), (0.76, -0.18), (0.90, 0.10), (1.00, 0.00)
    ]
    for index in 1..<points.count {
        let start = points[index - 1]
        let end = points[index]
        let startPoint = NSPoint(
            x: waveRect.minX + waveRect.width * start.0,
            y: centerY + waveRect.height * start.1
        )
        let endPoint = NSPoint(
            x: waveRect.minX + waveRect.width * end.0,
            y: centerY + waveRect.height * end.1
        )
        let distance = endPoint.x - startPoint.x
        wave.curve(
            to: endPoint,
            controlPoint1: NSPoint(x: startPoint.x + distance * 0.38, y: startPoint.y),
            controlPoint2: NSPoint(x: endPoint.x - distance * 0.38, y: endPoint.y)
        )
    }

    NSColor.white.setStroke()
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round
    wave.lineWidth = max(2, CGFloat(size) * 0.065)
    wave.stroke()

    let trace = NSBezierPath()
    trace.move(to: NSPoint(x: waveRect.minX + waveRect.width * 0.05, y: centerY - waveRect.height * 0.39))
    trace.curve(
        to: NSPoint(x: waveRect.maxX - waveRect.width * 0.05, y: centerY - waveRect.height * 0.39),
        controlPoint1: NSPoint(x: waveRect.minX + waveRect.width * 0.34, y: centerY - waveRect.height * 0.64),
        controlPoint2: NSPoint(x: waveRect.maxX - waveRect.width * 0.34, y: centerY - waveRect.height * 0.08)
    )
    NSColor.white.withAlphaComponent(0.42).setStroke()
    trace.lineCapStyle = .round
    trace.lineWidth = max(1, CGFloat(size) * 0.026)
    trace.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to render icon \(name)"])
    }
    try png.write(to: iconset.appendingPathComponent(name))
}

for variant in variants {
    try writeIcon(size: variant.0, name: variant.1)
}

try? fileManager.removeItem(at: output)
try? fileManager.removeItem(at: readmePreview)
try fileManager.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: readmePreview)

let icnsChunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

var chunks = Data()
for (type, fileName) in icnsChunks {
    let png = try Data(contentsOf: iconset.appendingPathComponent(fileName))
    guard let typeData = type.data(using: .ascii) else { throw NSError(domain: "AppIcon", code: 3) }
    chunks.append(typeData)
    appendBigEndian(UInt32(png.count + 8), to: &chunks)
    chunks.append(png)
}

var icns = Data("icns".utf8)
appendBigEndian(UInt32(chunks.count + 8), to: &icns)
icns.append(chunks)
try icns.write(to: output, options: .atomic)

print(output.path)
