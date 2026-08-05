#if os(macOS)
@preconcurrency import AppKit
import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum PNGReportRenderer {
    static func render(chart: ReportChart, width: Int = 1_200, height: Int = 650) throws -> Data {
        guard width > 0, height > 0 else { throw ReportExportError.renderingFailed("Chart dimensions must be positive.") }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReportExportError.renderingFailed("Could not create an image context.")
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(NSColor(calibratedWhite: 0.78, alpha: 1).cgColor)
        context.setLineWidth(1)
        let plot = CGRect(x: 76, y: 72, width: CGFloat(width - 112), height: CGFloat(height - 150))
        context.stroke(plot)
        drawChart(chart, in: context, plot: plot)
        drawText(chart.title, at: CGPoint(x: 76, y: CGFloat(height - 44)), size: 24, color: .black, context: context)
        drawText("\(chart.xLabel) · \(chart.yLabel)", at: CGPoint(x: 76, y: 30), size: 13, color: .darkGray, context: context)
        guard let image = context.makeImage() else { throw ReportExportError.renderingFailed("Could not create chart image.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ReportExportError.renderingFailed("Could not create PNG destination.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReportExportError.renderingFailed("Could not encode PNG.") }
        return output as Data
    }

    static func drawChart(_ chart: ReportChart, in context: CGContext, plot: CGRect) {
        guard !chart.points.isEmpty else { return }
        let xs = chart.points.map(\.x), ys = chart.points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minY = ys.min() ?? -1, maxY = ys.max() ?? 1
        let xRange = max(maxX - minX, 1e-12), yRange = max(maxY - minY, 1e-12)
        func point(_ item: ReportPoint) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((item.x - minX) / xRange) * plot.width, y: plot.minY + CGFloat((item.y - minY) / yRange) * plot.height)
        }
        context.saveGState()
        context.addRect(plot)
        context.clip()
        context.setStrokeColor(NSColor(calibratedRed: 0.15, green: 0.36, blue: 0.82, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.beginPath()
        for (index, item) in chart.points.enumerated() {
            let p = point(item)
            if index == 0 { context.move(to: p) } else { context.addLine(to: p) }
        }
        context.strokePath()
        context.setStrokeColor(NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.08, alpha: 0.85).cgColor)
        context.setLineWidth(1)
        for marker in chart.markers {
            let x = plot.minX + CGFloat((marker.x - minX) / xRange) * plot.width
            context.move(to: CGPoint(x: x, y: plot.minY))
            context.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func drawText(_ value: String, at point: CGPoint, size: CGFloat, color: NSColor, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]
        NSAttributedString(string: value, attributes: attributes).draw(at: point)
    }
}

enum PDFReportRenderer {
    static func render(_ document: ReportDocument) throws -> Data {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 46
        var pages: [NSImage] = []
        let text = textLines(document)
        var chunks: [[String]] = []
        var chunk: [String] = []
        for line in text {
            if chunk.count >= 39 { chunks.append(chunk); chunk = [] }
            chunk.append(line)
        }
        if !chunk.isEmpty || chunks.isEmpty { chunks.append(chunk) }
        for lines in chunks {
            try Task.checkCancellation()
            pages.append(makeTextPage(lines: lines, title: document.title, date: dateString(document.generatedAt), pageWidth: pageWidth, pageHeight: pageHeight, margin: margin, pageIndex: pages.count + 1, totalPages: chunks.count + document.charts.count))
        }
        for chart in document.charts {
            try Task.checkCancellation()
            pages.append(makeChartPage(chart: chart, title: document.title, date: dateString(document.generatedAt), pageWidth: pageWidth, pageHeight: pageHeight, margin: margin, pageIndex: pages.count + 1, totalPages: chunks.count + document.charts.count))
        }
        let pdf = PDFDocument()
        for (index, image) in pages.enumerated() {
            guard let page = PDFPage(image: image) else { throw ReportExportError.renderingFailed("Could not create PDF page \(index + 1).") }
            pdf.insert(page, at: index)
        }
        guard let data = pdf.dataRepresentation(), !data.isEmpty else { throw ReportExportError.renderingFailed("Could not encode PDF.") }
        return data
    }

    private static func textLines(_ document: ReportDocument) -> [String] {
        var lines = ["Executive Summary", document.executiveSummary, "", "Measurement Setup"]
        lines += document.measurementSetup.keys.sorted().map { "\($0): \(document.measurementSetup[$0] ?? "")" }
        if !document.devices.isEmpty {
            lines += ["", "Device Information"]
            lines += document.devices.map { "\($0.role): \($0.name) (\($0.transport))" }
        }
        if !document.signalConfiguration.isEmpty {
            lines += ["", "Signal Configuration"] + document.signalConfiguration.keys.sorted().map { "\($0): \(document.signalConfiguration[$0] ?? "")" }
        }
        if !document.audioFormat.isEmpty {
            lines += ["", "Audio Format"] + document.audioFormat.keys.sorted().map { "\($0): \(document.audioFormat[$0] ?? "")" }
        }
        lines += ["", "Delay Result"]
        for run in document.runs {
            lines.append("Run \(run.id.uuidString.prefix(8)): raw \(format(run.delay.milliseconds)) ms, calibrated \(format(run.delay.calibratedMilliseconds)) ms, quality \(run.quality.level)")
        }
        if let stats = document.statistics {
            lines += ["", "Statistical Summary", "count: \(stats.populationCount)", "mean: \(format(stats.meanMilliseconds)) ms", "median: \(format(stats.medianMilliseconds)) ms", "P95: \(format(stats.p95Milliseconds)) ms", "P99: \(format(stats.p99Milliseconds)) ms", "jitter (standard deviation): \(format(stats.jitterStandardDeviationMilliseconds)) ms"]
        }
        if let quality = document.quality { lines += ["", "Quality and Confidence", "level: \(quality.level)", "confidence: \(format(quality.confidence))", quality.summary] }
        if !document.warnings.isEmpty { lines += ["", "Warnings"] + document.warnings.map { "[\($0.severity)] \($0.title): \($0.detail)" } }
        if let calibration = document.calibration { lines += ["", "Calibration", "profile: \(calibration.profileName), method: \(calibration.method), offset: \(calibration.knownDelaySamples) samples, applied: \(calibration.applied)"] }
        if let drift = document.drift { lines += ["", "Drift", "relative drift: \(format(drift.relativePartsPerMillion)) ppm, residual: \(format(drift.fitResidualRMS)) samples"] }
        if !document.processingLog.isEmpty {
            lines += ["", "Processing Log"] + document.processingLog.map { "\($0.role) #\($0.sequence) \($0.operation): \($0.summary)" }
        }
        lines += ["", "Algorithm and App Version", "app: \(document.appVersion)", "algorithm: \(document.algorithmVersion)"]
        if !document.reproducibility.isEmpty {
            lines += ["", "Reproducibility Information"] + document.reproducibility.keys.sorted().map { "\($0): \(document.reproducibility[$0] ?? "")" }
        }
        if let notes = document.notes { lines += ["", "Notes", notes] }
        return lines.flatMap(wrap)
    }

    private static func makeTextPage(lines: [String], title: String, date: String, pageWidth: CGFloat, pageHeight: CGFloat, margin: CGFloat, pageIndex: Int, totalPages: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: pageWidth, height: pageHeight))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight).fill()
        drawString(title, at: CGPoint(x: margin, y: pageHeight - margin), size: 10, color: .secondaryLabelColor)
        drawString("AudioLink Lab", at: CGPoint(x: margin, y: pageHeight - margin - 22), size: 18, color: .labelColor)
        var y = pageHeight - margin - 62
        for line in lines {
            let heading = line == "Executive Summary" || line == "Measurement Setup" || line == "Device Information" || line == "Signal Configuration" || line == "Audio Format" || line == "Delay Result" || line == "Statistical Summary" || line == "Quality and Confidence" || line == "Warnings" || line == "Calibration" || line == "Drift" || line == "Processing Log" || line == "Algorithm and App Version" || line == "Reproducibility Information" || line == "Notes"
            drawString(line, at: CGPoint(x: margin, y: y), size: heading ? 12 : 9, color: heading ? .labelColor : .secondaryLabelColor)
            y -= heading ? 20 : 15
        }
        drawFooter(date: date, pageWidth: pageWidth, pageHeight: pageHeight, margin: margin, pageIndex: pageIndex, totalPages: totalPages)
        image.unlockFocus()
        return image
    }

    private static func makeChartPage(chart: ReportChart, title: String, date: String, pageWidth: CGFloat, pageHeight: CGFloat, margin: CGFloat, pageIndex: Int, totalPages: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: pageWidth, height: pageHeight))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight).fill()
        drawString(title, at: CGPoint(x: margin, y: pageHeight - margin), size: 10, color: .secondaryLabelColor)
        drawString(chart.title, at: CGPoint(x: margin, y: pageHeight - margin - 28), size: 18, color: .labelColor)
        if let data = try? PNGReportRenderer.render(chart: chart, width: Int(pageWidth - margin * 2), height: 480), let representation = NSBitmapImageRep(data: data) {
            let imageRep = NSImage(size: representation.size)
            imageRep.addRepresentation(representation)
            imageRep.draw(in: NSRect(x: margin, y: 170, width: pageWidth - margin * 2, height: 480))
        }
        drawString("\(chart.xLabel) · \(chart.yLabel)", at: CGPoint(x: margin, y: 145), size: 10, color: .secondaryLabelColor)
        drawFooter(date: date, pageWidth: pageWidth, pageHeight: pageHeight, margin: margin, pageIndex: pageIndex, totalPages: totalPages)
        image.unlockFocus()
        return image
    }

    private static func drawFooter(date: String, pageWidth: CGFloat, pageHeight: CGFloat, margin: CGFloat, pageIndex: Int, totalPages: Int) {
        drawString("AudioLink Lab · \(date) · page \(pageIndex) of \(totalPages)", at: CGPoint(x: margin, y: 24), size: 8, color: .secondaryLabelColor)
    }

    private static func drawString(_ value: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]).draw(at: point)
    }

    private static func wrap(_ value: String) -> [String] {
        guard value.count > 96 else { return [value] }
        var result: [String] = []
        var current = ""
        for word in value.split(separator: " ", omittingEmptySubsequences: false) {
            if current.count + word.count + 1 > 96 { result.append(current); current = "" }
            current += current.isEmpty ? String(word) : " \(word)"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func format(_ value: Double?) -> String { value.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "n/a" }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
#endif
