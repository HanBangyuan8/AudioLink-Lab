import Foundation

public struct ReportArtifact: Equatable, Sendable {
    public let fileName: String
    public let contentType: String
    public let data: Data

    public init(fileName: String, contentType: String, data: Data) {
        self.fileName = fileName
        self.contentType = contentType
        self.data = data
    }
}

/// Streaming-friendly report façade. Rendering is kept out of SwiftUI and
/// checks cancellation between expensive sections and rows.
public enum ReportExporter {
    public static func artifacts(
        for document: ReportDocument,
        format: ReportExportFormat,
        prettyJSON: Bool = true
    ) async throws -> [ReportArtifact] {
        try Task.checkCancellation()
        switch format {
        case .json:
            return [ReportArtifact(fileName: "report.json", contentType: "application/json", data: try JSONCodec.encode(document, pretty: prettyJSON))]
        case .csv:
            return try await CSVReportRenderer.artifacts(for: document)
        case .html:
            return [ReportArtifact(fileName: "report.html", contentType: "text/html; charset=utf-8", data: Data(try HTMLReportRenderer.render(document).utf8))]
        case .pdf:
            #if os(macOS)
            return [ReportArtifact(fileName: "report.pdf", contentType: "application/pdf", data: try PDFReportRenderer.render(document))]
            #else
            throw ReportExportError.unsupportedFormat("PDF is available in the macOS report exporter.")
            #endif
        case .png:
            #if os(macOS)
            guard let chart = document.charts.first else { throw ReportExportError.chartUnavailable }
            return [ReportArtifact(fileName: "\(safeFileName(chart.id)).png", contentType: "image/png", data: try PNGReportRenderer.render(chart: chart))]
            #else
            throw ReportExportError.unsupportedFormat("PNG is available in the macOS report exporter.")
            #endif
        }
    }

    /// Writes one or more artifacts. CSV is represented by a directory because
    /// the run table, session summary and optional drift table have different
    /// schemas. Other formats use the supplied file URL.
    @discardableResult
    public static func write(
        document: ReportDocument,
        format: ReportExportFormat,
        to destination: URL,
        prettyJSON: Bool = true
    ) async throws -> [URL] {
        let artifacts = try await artifacts(for: document, format: format, prettyJSON: prettyJSON)
        try Task.checkCancellation()
        let fileManager = FileManager.default
        var urls: [URL] = []
        do {
            if format == .csv {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                for artifact in artifacts {
                    try Task.checkCancellation()
                    let url = destination.appendingPathComponent(artifact.fileName)
                    try artifact.data.write(to: url, options: .atomic)
                    urls.append(url)
                }
            } else {
                let parent = destination.deletingLastPathComponent()
                if !parent.path.isEmpty { try fileManager.createDirectory(at: parent, withIntermediateDirectories: true) }
                guard let artifact = artifacts.first else { throw ReportExportError.invalidDestination }
                try artifact.data.write(to: destination, options: .atomic)
                urls.append(destination)
            }
            return urls
        } catch is CancellationError {
            throw ReportExportError.cancelled
        } catch let error as ReportExportError {
            throw error
        } catch {
            throw ReportExportError.writeFailed(error.localizedDescription)
        }
    }

    private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }.reduce(into: "") { $0.append($1) }
    }
}

public enum JSONCodec {
    public static func encode(_ document: ReportDocument, pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> ReportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO 8601 report date.")
            }
            return date
        }
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReportDocument.self, from: data)
    }
}

private enum CSVReportRenderer {
    static func artifacts(for document: ReportDocument) async throws -> [ReportArtifact] {
        let header = [
            "run_id", "session_id", "created_at", "completed_at", "reference_file", "recording_file",
            "delay_samples", "delay_fractional_samples", "delay_ms", "calibrated_delay_ms",
            "sample_rate_hz", "peak_correlation", "confidence", "quality", "warning_count"
        ]
        var rows = [header]
        for run in document.runs {
            try Task.checkCancellation()
            rows.append([
                run.id.uuidString,
                run.sessionID.uuidString,
                reportDateString(run.createdAt),
                run.completedAt.map(reportDateString) ?? "",
                run.reference.fileName,
                run.recording.fileName,
                csvNumber(run.delay.integerSamples.map(Double.init)),
                csvNumber(run.delay.fractionalSamples),
                csvNumber(run.delay.milliseconds),
                csvNumber(run.delay.calibratedMilliseconds),
                csvNumber(run.delay.sampleRateHertz),
                csvNumber(run.delay.peakCorrelation),
                csvNumber(run.delay.confidence),
                run.quality.level,
                String(run.warnings.count)
            ].map(escape))
        }
        let runCSV = rows.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
        var artifacts = [ReportArtifact(fileName: "runs.csv", contentType: "text/csv", data: Data(runCSV.utf8))]
        if let stats = document.statistics {
            let summary = [
                ["metric", "value", "unit"],
                ["outcome_count", String(stats.outcomeCount), "count"],
                ["success_count", String(stats.successCount), "count"],
                ["failure_count", String(stats.failureCount), "count"],
                ["mean", csvNumber(stats.meanMilliseconds), "milliseconds"],
                ["median", csvNumber(stats.medianMilliseconds), "milliseconds"],
                ["p95", csvNumber(stats.p95Milliseconds), "milliseconds"],
                ["p99", csvNumber(stats.p99Milliseconds), "milliseconds"],
                ["jitter_standard_deviation", csvNumber(stats.jitterStandardDeviationMilliseconds), "milliseconds"],
                ["peak_to_peak_jitter", csvNumber(stats.peakToPeakJitterMilliseconds), "milliseconds"]
            ].map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
            artifacts.append(ReportArtifact(fileName: "session_summary.csv", contentType: "text/csv", data: Data(summary.utf8)))
        }
        if let drift = document.drift, !drift.observations.isEmpty {
            let header = "event_index,expected_sample,observed_sample,error_samples,time_seconds,quality\n"
            let values = drift.observations.map { observation in
                [String(observation.eventIndex), csvNumber(observation.expectedSample), csvNumber(observation.observedSample), csvNumber(observation.errorSamples), csvNumber(observation.timeSeconds), csvNumber(observation.quality)].map(escape).joined(separator: ",")
            }.joined(separator: "\n")
            artifacts.append(ReportArtifact(fileName: "drift_observations.csv", contentType: "text/csv", data: Data((header + values + "\n").utf8)))
        }
        return artifacts
    }

    private static func csvNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private enum HTMLReportRenderer {
    static func render(_ document: ReportDocument) throws -> String {
        try Task.checkCancellation()
        var html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(escape(document.title))</title>
        <style> :root{color-scheme:light} body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#1d2430;background:#fff;margin:0;padding:32px;line-height:1.45} main{max-width:980px;margin:0 auto} h1{font-size:28px;margin:0 0 4px} h2{font-size:18px;border-bottom:1px solid #d9dee7;padding-bottom:6px;margin-top:28px} .muted{color:#667085;font-size:13px} .summary{background:#f3f6fa;border-radius:10px;padding:14px 16px} table{border-collapse:collapse;width:100%;font-size:13px} th,td{text-align:left;border-bottom:1px solid #e4e7ec;padding:7px 8px;vertical-align:top} th{color:#526070;font-weight:600} code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace} .warning{border-left:3px solid #dc8b21;padding:7px 10px;margin:7px 0;background:#fff7e6} .chart{border:1px solid #e4e7ec;border-radius:8px;padding:8px;margin:10px 0} svg{width:100%;height:240px} @media print{body{padding:14mm;color:#000} .summary{background:#f4f4f4;break-inside:avoid}.chart{break-inside:avoid} h2{break-after:avoid}}</style></head><body><main>
        <h1>\(escape(document.title))</h1><div class="muted">AudioLink Lab · generated \(escape(reportDateString(document.generatedAt)))</div>
        """
        html += section(title: "Executive Summary", body: "<div class=\"summary\">\(escape(document.executiveSummary))</div>")
        try Task.checkCancellation()
        if !document.measurementSetup.isEmpty { html += keyValueSection("Measurement Setup", document.measurementSetup) }
        if !document.devices.isEmpty { html += deviceSection(document.devices) }
        if !document.signalConfiguration.isEmpty { html += keyValueSection("Signal Configuration", document.signalConfiguration) }
        if !document.audioFormat.isEmpty { html += keyValueSection("Audio Format", document.audioFormat) }
        html += runSection(document.runs)
        if let stats = document.statistics { html += statisticsSection(stats) }
        else { html += section(title: "Statistical Summary", body: "<p class=\"muted\">No aggregate statistics are available for this report.</p>") }
        if let quality = document.quality { html += qualitySection(quality) }
        if !document.warnings.isEmpty { html += warningsSection(document.warnings) }
        else { html += section(title: "Warnings", body: "<p class=\"muted\">No warnings recorded.</p>") }
        if let calibration = document.calibration { html += calibrationSection(calibration) }
        if let drift = document.drift { html += driftSection(drift) }
        if !document.charts.isEmpty {
            html += section(title: "Charts", body: document.charts.map(chartSVG).joined())
        }
        if !document.processingLog.isEmpty { html += processingSection(document.processingLog) }
        html += keyValueSection("Algorithm and App Version", ["app_version": document.appVersion, "algorithm_version": document.algorithmVersion])
        if !document.reproducibility.isEmpty { html += keyValueSection("Reproducibility Information", document.reproducibility) }
        if let notes = document.notes { html += section(title: "Notes", body: "<p>\(escape(notes))</p>") }
        html += "</main></body></html>"
        return html
    }

    private static func section(title: String, body: String) -> String { "<section><h2>\(escape(title))</h2>\(body)</section>" }

    private static func keyValueSection(_ title: String, _ values: [String: String]) -> String {
        let rows = values.keys.sorted().map { key in "<tr><th>\(escape(key))</th><td>\(escape(values[key] ?? ""))</td></tr>" }.joined()
        return section(title: title, body: "<table><tbody>\(rows)</tbody></table>")
    }

    private static func deviceSection(_ devices: [ReportDevice]) -> String {
        let rows = devices.map { device in
            "<tr><td>\(escape(device.role))</td><td>\(escape(device.name))</td><td>\(escape(device.manufacturer ?? ""))</td><td>\(escape(device.transport))</td><td>\(device.diagnosticIdentifier.map(escape) ?? "redacted")</td></tr>"
        }.joined()
        return section(title: "Device Information", body: "<table><thead><tr><th>Role</th><th>Name</th><th>Manufacturer</th><th>Transport</th><th>Identifier</th></tr></thead><tbody>\(rows)</tbody></table>")
    }

    private static func runSection(_ runs: [ReportRun]) -> String {
        let rows = runs.map { run in
            "<tr><td><code>\(run.id.uuidString)</code></td><td>\(escape(run.reference.fileName))</td><td>\(escape(run.recording.fileName))</td><td>\(number(run.delay.milliseconds)) ms</td><td>\(number(run.delay.calibratedMilliseconds)) ms</td><td>\(escape(run.quality.level))</td></tr>"
        }.joined()
        return section(title: "Delay Result", body: "<table><thead><tr><th>Run</th><th>Reference</th><th>Recording</th><th>Raw delay</th><th>Calibrated</th><th>Quality</th></tr></thead><tbody>\(rows)</tbody></table>")
    }

    private static func statisticsSection(_ stats: ReportStatistics) -> String {
        keyValueSection("Statistical Summary", [
            "count": String(stats.populationCount), "mean_ms": number(stats.meanMilliseconds), "median_ms": number(stats.medianMilliseconds),
            "p95_ms": number(stats.p95Milliseconds), "p99_ms": number(stats.p99Milliseconds), "jitter_stddev_ms": number(stats.jitterStandardDeviationMilliseconds),
            "outlier_method": stats.outlierMethod ?? "not available"
        ])
    }

    private static func qualitySection(_ quality: ReportQuality) -> String {
        let metrics = quality.metrics.keys.sorted().map { "<tr><th>\(escape($0))</th><td>\(number(quality.metrics[$0]))</td></tr>" }.joined()
        return section(title: "Quality and Confidence", body: "<p><strong>\(escape(quality.level))</strong> · \(number(quality.confidence)) confidence</p><p>\(escape(quality.summary))</p><table><tbody>\(metrics)</tbody></table>")
    }

    private static func warningsSection(_ warnings: [ReportWarning]) -> String {
        section(title: "Warnings", body: warnings.map { "<div class=\"warning\"><strong>\(escape($0.title))</strong> [\(escape($0.severity))]<br>\(escape($0.detail))<br><span class=\"muted\">Recommendation: \(escape($0.recommendation))</span></div>" }.joined())
    }

    private static func calibrationSection(_ calibration: ReportCalibration) -> String { keyValueSection("Calibration", ["profile": calibration.profileName, "method": calibration.method, "known_delay_samples": String(calibration.knownDelaySamples), "applied": String(calibration.applied), "confidence": number(calibration.confidence)]) }

    private static func driftSection(_ drift: ReportDrift) -> String { keyValueSection("Drift", ["relative_ppm": number(drift.relativePartsPerMillion), "constant_offset_samples": number(drift.constantOffsetSamples), "fit_residual_rms_samples": number(drift.fitResidualRMS), "confidence": number(drift.confidence), "non_linear_warning": String(drift.nonLinearWarning), "observation_count": String(drift.observations.count)]) }

    private static func processingSection(_ steps: [ReportProcessingStep]) -> String {
        let rows = steps.map { "<tr><td>\(escape($0.role))</td><td>\($0.sequence)</td><td>\(escape($0.operation))</td><td>\(escape($0.summary))</td><td>\($0.inputFrames) → \($0.outputFrames)</td></tr>" }.joined()
        return section(title: "Processing Log", body: "<table><thead><tr><th>Role</th><th>#</th><th>Operation</th><th>Summary</th><th>Frames</th></tr></thead><tbody>\(rows)</tbody></table>")
    }

    private static func chartSVG(_ chart: ReportChart) -> String {
        guard !chart.points.isEmpty else { return "<div class=\"chart\"><strong>\(escape(chart.title))</strong><p class=\"muted\">No chart data available.</p></div>" }
        let width = 900.0, height = 230.0, left = 52.0, right = 16.0, top = 18.0, bottom = 34.0
        let xs = chart.points.map(\.x), ys = chart.points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minY = ys.min() ?? -1, maxY = ys.max() ?? 1
        let xRange = max(maxX - minX, 1e-12), yRange = max(maxY - minY, 1e-12)
        let coordinates = chart.points.map { point in
            let x = left + (point.x - minX) / xRange * (width - left - right)
            let y = top + (maxY - point.y) / yRange * (height - top - bottom)
            return String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), x, y)
        }.joined(separator: " ")
        let markers = chart.markers.map { marker in
            let x = left + (marker.x - minX) / xRange * (width - left - right)
            let y = marker.y.map { top + (maxY - $0) / yRange * (height - top - bottom) } ?? top + 12
            return "<line x1=\"\(x)\" x2=\"\(x)\" y1=\"\(top)\" y2=\"\(height - bottom)\" stroke=\"#d17b16\" stroke-dasharray=\"4 3\"/><text x=\"\(x + 4)\" y=\"\(y)\" fill=\"#9b5c0d\" font-size=\"11\">\(escape(marker.label))</text>"
        }.joined()
        return "<div class=\"chart\"><strong>\(escape(chart.title))</strong><svg viewBox=\"0 0 \(width) \(height)\" role=\"img\" aria-label=\"\(escape(chart.title))\"><line x1=\"\(left)\" x2=\"\(width-right)\" y1=\"\(height-bottom)\" y2=\"\(height-bottom)\" stroke=\"#9aa3b2\"/><polyline points=\"\(coordinates)\" fill=\"none\" stroke=\"#356ae6\" stroke-width=\"1.8\"/>\(markers)</svg><div class=\"muted\">\(escape(chart.xLabel)) · \(escape(chart.yLabel))</div></div>"
    }

    private static func number(_ value: Double?) -> String { value.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "n/a" }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}

private func reportDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
