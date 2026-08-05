import AudioLinkDSP
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PlotExportAppearance: String, Codable, Sendable {
    case light
    case dark
}

enum PlotExportContent: Sendable {
    case waveform(WaveformRenderData)
    case correlation(CorrelationRenderData)
    case peakDetail(PeakDetailRenderData)
}

struct PlotExportDocument: Sendable {
    let title: String
    let content: PlotExportContent
    let appearance: PlotExportAppearance

    init(title: String, content: PlotExportContent, appearance: PlotExportAppearance) {
        self.title = title
        self.content = content
        self.appearance = appearance
    }
}

enum PlotPNGExportError: Error, Equatable, Sendable {
    case invalidSize(width: Int, height: Int)
    case contextCreationFailed
    case imageCreationFailed
    case encodingFailed
}

struct PlotPNGExporter: Sendable {
    func pngData(
        document: PlotExportDocument,
        width: Int,
        height: Int
    ) throws -> Data {
        guard (64...8_192).contains(width), (64...8_192).contains(height) else {
            throw PlotPNGExportError.invalidSize(width: width, height: height)
        }
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PlotPNGExportError.contextCreationFailed
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let palette = PlotExportPalette(appearance: document.appearance)
        context.setFillColor(palette.background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(
            document.title,
            at: CGPoint(x: 28, y: 18),
            fontSize: 22,
            color: palette.primaryText,
            context: context
        )

        let plotRect = CGRect(
            x: 72,
            y: 62,
            width: max(1, CGFloat(width) - 100),
            height: max(1, CGFloat(height) - 116)
        )
        drawPlotBackground(plotRect, palette: palette, context: context)
        switch document.content {
        case let .waveform(data):
            drawWaveform(data, in: plotRect, palette: palette, context: context)
        case let .correlation(data):
            drawCorrelation(data, in: plotRect, palette: palette, context: context)
        case let .peakDetail(data):
            drawPeakDetail(data, in: plotRect, palette: palette, context: context)
        }

        guard let image = context.makeImage() else {
            throw PlotPNGExportError.imageCreationFailed
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PlotPNGExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PlotPNGExportError.encodingFailed
        }
        return mutableData as Data
    }

    private func drawPlotBackground(
        _ rect: CGRect,
        palette: PlotExportPalette,
        context: CGContext
    ) {
        context.setFillColor(palette.plotBackground)
        context.fill(rect)
        context.setStrokeColor(palette.grid)
        context.setLineWidth(1)
        for step in 0...4 {
            let x = rect.minX + rect.width * CGFloat(step) / 4
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(step) / 4
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }

    private func drawWaveform(
        _ data: WaveformRenderData,
        in rect: CGRect,
        palette: PlotExportPalette,
        context: CGContext
    ) {
        let trackHeight = rect.height / 2
        drawWaveformTrack(
            data.reference,
            viewport: data.viewport,
            rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: trackHeight),
            color: palette.reference,
            palette: palette,
            context: context
        )
        drawWaveformTrack(
            data.recording,
            viewport: data.viewport,
            rect: CGRect(x: rect.minX, y: rect.minY + trackHeight, width: rect.width, height: trackHeight),
            color: palette.recording,
            palette: palette,
            context: context
        )
        for marker in data.markers
        where marker.position >= data.viewport.visibleLowerBound
            && marker.position <= data.viewport.visibleUpperBound {
            let x = xPosition(marker.position, viewport: data.viewport, rect: rect)
            context.setStrokeColor(palette.marker)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            drawText(marker.label, at: CGPoint(x: min(x + 5, rect.maxX - 130), y: rect.minY + 5), fontSize: 11, color: palette.marker, context: context)
        }
        drawText("Reference", at: CGPoint(x: rect.minX + 8, y: rect.minY + 6), fontSize: 12, color: palette.reference, context: context)
        drawText("Recording", at: CGPoint(x: rect.minX + 8, y: rect.midY + 6), fontSize: 12, color: palette.recording, context: context)
        drawWaveformAxis(viewport: data.viewport, sampleRate: data.reference.sampleRate.hertz, rect: rect, palette: palette, context: context)
        drawText("Normalized amplitude", at: CGPoint(x: 8, y: rect.midY - 8), fontSize: 11, color: palette.secondaryText, context: context)
    }

    private func drawWaveformTrack(
        _ track: WaveformTrackRenderData,
        viewport: PlotViewport,
        rect: CGRect,
        color: CGColor,
        palette: PlotExportPalette,
        context: CGContext
    ) {
        context.setStrokeColor(palette.zeroLine)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: rect.minX, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.strokePath()
        context.setStrokeColor(color)
        context.setLineWidth(1)
        for bin in track.bins {
            let x = xPosition(bin.centerSamplePosition, viewport: viewport, rect: rect)
            let minimumY = amplitudeY(Double(bin.minimum), rect: rect)
            let maximumY = amplitudeY(Double(bin.maximum), rect: rect)
            context.move(to: CGPoint(x: x, y: maximumY))
            context.addLine(to: CGPoint(x: x, y: minimumY))
        }
        context.strokePath()
    }

    private func drawCorrelation(
        _ data: CorrelationRenderData,
        in rect: CGRect,
        palette: PlotExportPalette,
        context: CGContext
    ) {
        context.setStrokeColor(palette.zeroLine)
        context.move(to: CGPoint(x: rect.minX, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.strokePath()
        context.setStrokeColor(palette.correlation)
        context.setLineWidth(1)
        for bin in data.bins {
            let x = xPosition(Double(bin.strongestLag), viewport: data.viewport, rect: rect)
            context.move(to: CGPoint(x: x, y: correlationY(Double(bin.maximum), rect: rect)))
            context.addLine(to: CGPoint(x: x, y: correlationY(Double(bin.minimum), rect: rect)))
        }
        context.strokePath()

        for sign in [-1.0, 1.0] {
            let y = correlationY(sign * data.confidenceThresholdMagnitude, rect: rect)
            context.setStrokeColor(palette.threshold)
            context.setLineDash(phase: 0, lengths: [5, 4])
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])

        for marker in data.markers
        where marker.kind != .confidenceThreshold
            && marker.position >= data.viewport.visibleLowerBound
            && marker.position <= data.viewport.visibleUpperBound {
            let x = xPosition(marker.position, viewport: data.viewport, rect: rect)
            let color = marker.kind == .primaryPeak ? palette.primaryPeak : palette.marker
            context.setStrokeColor(color)
            context.setLineWidth(marker.kind == .primaryPeak ? 2 : 1)
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.strokePath()
            if [.primaryPeak, .secondaryPeak, .candidatePeak].contains(marker.kind) {
                drawText(marker.label, at: CGPoint(x: min(x + 4, rect.maxX - 100), y: rect.minY + 6), fontSize: 10, color: color, context: context)
            }
        }
        drawSampleTimeAxis(viewport: data.viewport, sampleRate: data.sampleRate.hertz, rect: rect, palette: palette, context: context)
        drawText("Normalized correlation (−1…+1)", at: CGPoint(x: 8, y: rect.midY - 8), fontSize: 11, color: palette.secondaryText, context: context)
        if data.peakAtSearchBoundary {
            drawText("WARNING: primary peak is at the search boundary", at: CGPoint(x: rect.minX + 8, y: rect.minY + 8), fontSize: 12, color: palette.warning, context: context)
        }
    }

    private func drawPeakDetail(
        _ data: PeakDetailRenderData,
        in rect: CGRect,
        palette: PlotExportPalette,
        context: CGContext
    ) {
        context.setStrokeColor(palette.zeroLine)
        context.move(to: CGPoint(x: rect.minX, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.strokePath()
        drawLine(data.samples, viewport: data.viewport, rect: rect, color: palette.correlation, width: 1.5, context: context)
        context.setLineDash(phase: 0, lengths: [6, 3])
        drawLine(data.interpolationCurve, viewport: data.viewport, rect: rect, color: palette.interpolation, width: 2, context: context)
        context.setLineDash(phase: 0, lengths: [])

        for sign in [-1.0, 1.0] {
            let y = correlationY(sign * data.localNoiseFloor, rect: rect)
            context.setStrokeColor(palette.threshold)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        for marker in data.markers {
            let x = xPosition(marker.position, viewport: data.viewport, rect: rect)
            let color = marker.kind == .fractionalPeak ? palette.interpolation : palette.primaryPeak
            context.setStrokeColor(color)
            context.setLineWidth(2)
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.strokePath()
            drawText(marker.label, at: CGPoint(x: min(x + 4, rect.maxX - 110), y: rect.minY + 6), fontSize: 10, color: color, context: context)
        }
        if let width = data.peakWidthSamples {
            let center = data.fractionalPeakLag ?? Double(data.integerPeakLag)
            let y = rect.maxY - 20
            let x0 = xPosition(center - width / 2, viewport: data.viewport, rect: rect)
            let x1 = xPosition(center + width / 2, viewport: data.viewport, rect: rect)
            context.setStrokeColor(palette.marker)
            context.move(to: CGPoint(x: x0, y: y))
            context.addLine(to: CGPoint(x: x1, y: y))
            context.strokePath()
            drawText(String(format: "width %.2f samples", width), at: CGPoint(x: min(x0, rect.maxX - 120), y: y - 16), fontSize: 10, color: palette.marker, context: context)
        }
        drawSampleTimeAxis(viewport: data.viewport, sampleRate: data.sampleRate.hertz, rect: rect, palette: palette, context: context)
        drawText("Correlation neighborhood", at: CGPoint(x: 8, y: rect.midY - 8), fontSize: 11, color: palette.secondaryText, context: context)
    }

    private func drawLine(
        _ points: [PeakDetailPoint],
        viewport: PlotViewport,
        rect: CGRect,
        color: CGColor,
        width: CGFloat,
        context: CGContext
    ) {
        guard let first = points.first else { return }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.move(to: CGPoint(x: xPosition(first.lag, viewport: viewport, rect: rect), y: correlationY(first.value, rect: rect)))
        for point in points.dropFirst() {
            context.addLine(to: CGPoint(x: xPosition(point.lag, viewport: viewport, rect: rect), y: correlationY(point.value, rect: rect)))
        }
        context.strokePath()
    }

    private func drawSampleTimeAxis(
        viewport: PlotViewport,
        sampleRate: Double,
        rect: CGRect,
        palette: PlotExportPalette,
        context: CGContext
    ) {
        for step in 0...4 {
            let normalized = Double(step) / 4
            let value = viewport.value(atNormalizedPosition: normalized)
            let x = rect.minX + rect.width * CGFloat(normalized)
            let label = String(format: "%.0f smp / %.3f ms", value, value / sampleRate * 1_000)
            drawText(label, at: CGPoint(x: max(rect.minX, min(x - 42, rect.maxX - 90)), y: rect.maxY + 8), fontSize: 9, color: palette.secondaryText, context: context)
        }
    }

    private func drawWaveformAxis(
        viewport: PlotViewport,
        sampleRate: Double,
        rect: CGRect,
        palette: PlotExportPalette,
        context: CGContext
    ) {
        for step in 0...4 {
            let normalized = Double(step) / 4
            let value = viewport.value(atNormalizedPosition: normalized)
            let x = rect.minX + rect.width * CGFloat(normalized)
            let label = String(format: "%.3f s / %.0f smp", value / sampleRate, value)
            drawText(label, at: CGPoint(x: max(rect.minX, min(x - 42, rect.maxX - 90)), y: rect.maxY + 8), fontSize: 9, color: palette.secondaryText, context: context)
        }
    }

    private func xPosition(_ value: Double, viewport: PlotViewport, rect: CGRect) -> CGFloat {
        rect.minX + rect.width * CGFloat(viewport.normalizedPosition(for: value))
    }

    private func amplitudeY(_ value: Double, rect: CGRect) -> CGFloat {
        rect.midY - CGFloat(min(1, max(-1, value))) * rect.height * 0.45
    }

    private func correlationY(_ value: Double, rect: CGRect) -> CGFloat {
        rect.midY - CGFloat(min(1, max(-1, value))) * rect.height * 0.45
    }

    private func drawText(
        _ text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        color: CGColor,
        context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("SFMono-Regular" as CFString, fontSize, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y + fontSize)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private struct PlotExportPalette {
    let background: CGColor
    let plotBackground: CGColor
    let primaryText: CGColor
    let secondaryText: CGColor
    let grid: CGColor
    let zeroLine: CGColor
    let reference: CGColor
    let recording: CGColor
    let correlation: CGColor
    let interpolation: CGColor
    let primaryPeak: CGColor
    let marker: CGColor
    let threshold: CGColor
    let warning: CGColor

    init(appearance: PlotExportAppearance) {
        let dark = appearance == .dark
        background = CGColor(red: dark ? 0.07 : 0.97, green: dark ? 0.075 : 0.975, blue: dark ? 0.085 : 0.985, alpha: 1)
        plotBackground = CGColor(red: dark ? 0.11 : 1, green: dark ? 0.115 : 1, blue: dark ? 0.13 : 1, alpha: 1)
        primaryText = CGColor(gray: dark ? 0.94 : 0.10, alpha: 1)
        secondaryText = CGColor(gray: dark ? 0.68 : 0.38, alpha: 1)
        grid = CGColor(gray: dark ? 0.25 : 0.84, alpha: 0.8)
        zeroLine = CGColor(gray: dark ? 0.48 : 0.55, alpha: 1)
        reference = CGColor(red: 0.18, green: 0.55, blue: 0.96, alpha: 1)
        recording = CGColor(red: 0.96, green: 0.48, blue: 0.16, alpha: 1)
        correlation = CGColor(red: dark ? 0.55 : 0.34, green: 0.42, blue: dark ? 0.98 : 0.78, alpha: 1)
        interpolation = CGColor(red: 0.10, green: 0.72, blue: 0.58, alpha: 1)
        primaryPeak = CGColor(red: 0.92, green: 0.20, blue: 0.34, alpha: 1)
        marker = CGColor(red: 0.74, green: 0.44, blue: 0.96, alpha: 1)
        threshold = CGColor(red: 0.82, green: 0.58, blue: 0.18, alpha: 1)
        warning = CGColor(red: 0.96, green: 0.42, blue: 0.10, alpha: 1)
    }
}
