import AudioLinkReporting
import PDFKit
import XCTest

final class ReportExporterTests: XCTestCase {
    func testJSONRoundTripAndPrivacyDefault() throws {
        let document = makeDocument(runCount: 1)
        let data = try JSONCodec.encode(document)
        let decoded = try JSONCodec.decode(data)
        XCTAssertEqual(decoded.reportID, document.reportID)
        XCTAssertEqual(decoded.runs, document.runs)
        XCTAssertEqual(decoded.title, document.title)
        XCTAssertLessThan(abs(decoded.generatedAt.timeIntervalSince(document.generatedAt)), 0.0011)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("schema_version"))
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.contains("\"diagnostic_identifier\""))
        XCTAssertFalse(text.contains("\"anonymous_identifier\""))
    }

    func testCSVEscapingIsLocaleIndependent() async throws {
        var document = makeDocument(runCount: 1)
        let file = ReportAudioFile(role: "reference", fileName: "a,\"quoted\".wav", container: "wav", encoding: "pcm16", sampleRateHertz: 48_000, channelCount: 1, bitDepth: 32, interleaved: false, frameCount: 100, durationSeconds: 100.0 / 48_000, peak: 0.5, rms: 0.1, clippingSampleCount: 0, dcOffset: 0)
        let run = document.runs[0]
        document = ReportDocument(schemaVersion: document.schemaVersion, reportID: document.reportID, title: document.title, generatedAt: document.generatedAt, sessionID: document.sessionID, measurementType: document.measurementType, executiveSummary: document.executiveSummary, measurementSetup: document.measurementSetup, devices: document.devices, signalConfiguration: document.signalConfiguration, audioFormat: document.audioFormat, runs: [ReportRun(id: run.id, sessionID: run.sessionID, createdAt: run.createdAt, completedAt: run.completedAt, reference: file, recording: run.recording, delay: run.delay, quality: run.quality)], statistics: document.statistics, quality: document.quality, warnings: document.warnings, calibration: document.calibration, drift: document.drift, charts: document.charts, processingLog: document.processingLog, appVersion: document.appVersion, algorithmVersion: document.algorithmVersion, reproducibility: document.reproducibility, notes: document.notes, privacy: document.privacy)
        let artifacts = try await ReportExporter.artifacts(for: document, format: .csv)
        let csv = String(decoding: try XCTUnwrap(artifacts.first?.data), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"a,\"\"quoted\"\".wav\""))
        XCTAssertTrue(csv.contains("1.255208333"))
        XCTAssertFalse(csv.contains("1,25"))
    }

    func testHTMLContainsReportSectionsAndMissingChartsAreSafe() async throws {
        let document = makeDocument(runCount: 1)
        let htmlArtifacts = try await ReportExporter.artifacts(for: document, format: .html)
        let htmlData = try XCTUnwrap(htmlArtifacts.first?.data)
        let html = String(decoding: htmlData, as: UTF8.self)
        for section in ["Executive Summary", "Measurement Setup", "Device Information", "Signal Configuration", "Audio Format", "Delay Result", "Statistical Summary", "Quality and Confidence", "Warnings", "Calibration", "Drift", "Algorithm and App Version", "Reproducibility Information", "Notes"] {
            XCTAssertTrue(html.contains(section), "missing \(section)")
        }
    }

    func testPDFAndPNGHaveValidOutput() async throws {
        let document = makeDocument(runCount: 1)
        let pdfArtifacts = try await ReportExporter.artifacts(for: document, format: .pdf)
        let pdf = try XCTUnwrap(pdfArtifacts.first?.data)
        XCTAssertGreaterThan(pdf.count, 100)
        XCTAssertGreaterThan(PDFDocument(data: pdf)?.pageCount ?? 0, 0)
        let pngArtifacts = try await ReportExporter.artifacts(for: document, format: .png)
        let png = try XCTUnwrap(pngArtifacts.first?.data)
        XCTAssertEqual(pngArtifacts.first?.fileName, "correlation.png")
        XCTAssertEqual(Data(png.prefix(8)), Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testEmptyAndLargeSessionCSV() async throws {
        let empty = makeDocument(runCount: 0)
        let emptyArtifacts = try await ReportExporter.artifacts(for: empty, format: .json)
        XCTAssertFalse(emptyArtifacts.isEmpty)
        let large = makeDocument(runCount: 100)
        let artifacts = try await ReportExporter.artifacts(for: large, format: .csv)
        let csv = String(decoding: try XCTUnwrap(artifacts.first?.data), as: UTF8.self)
        XCTAssertEqual(csv.split(separator: "\n", omittingEmptySubsequences: true).count, 101)
    }

    func testCancellationAndWriteFailureAreStructured() async throws {
        let document = makeDocument(runCount: 100)
        let task = Task { try await ReportExporter.artifacts(for: document, format: .json) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is ReportExportError || error is CancellationError)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audiolink-report-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: root)
        do {
            _ = try await ReportExporter.write(document: document, format: .json, to: root.appendingPathComponent("report.json"))
            XCTFail("expected write failure")
        } catch let error as ReportExportError {
            guard case .writeFailed = error else { return XCTFail("wrong error \(error)") }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDocument(runCount: Int) -> ReportDocument {
        let device = ReportDevice(role: "input", name: "Test Interface", manufacturer: "AudioLink", transport: "usb", supportsInput: true, supportsOutput: false)
        let chart = ReportChart(id: "correlation", title: "Correlation", kind: "line", points: [ReportPoint(x: -1, y: 0, xUnit: "ms", yUnit: "coefficient"), ReportPoint(x: 0, y: 0.9, xUnit: "ms", yUnit: "coefficient"), ReportPoint(x: 1, y: 0.1, xUnit: "ms", yUnit: "coefficient")], markers: [ReportChartMarker(label: "peak", x: 0)], xLabel: "Lag (ms)", yLabel: "Correlation")
        let runs = (0..<runCount).map { index in
            let id = UUID()
            let file = ReportAudioFile(role: "reference", fileName: "reference.wav", container: "wav", encoding: "pcm16", sampleRateHertz: 48_000, channelCount: 1, bitDepth: 32, interleaved: false, frameCount: 48_000, durationSeconds: 1, peak: 0.8, rms: 0.2, clippingSampleCount: 0, dcOffset: 0)
            return ReportRun(id: id, sessionID: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), completedAt: Date(timeIntervalSince1970: 1_700_000_001 + Double(index)), reference: file, recording: file, delay: ReportDelay(integerSamples: 60, fractionalSamples: 60.25, milliseconds: 1.255208333, sampleRateHertz: 48_000, peakCorrelation: 0.92, peakToSidelobeRatio: 4.2, confidence: 0.91, polarity: "normal"), quality: ReportQuality(level: "good", confidence: 0.91, summary: "Stable synthetic measurement.", metrics: ["primaryCorrelation": 0.92], issues: [], shouldRemeasure: false), warnings: [], notes: "synthetic")
        }
        return ReportDocument(title: "Synthetic AudioLink Report", sessionID: UUID(), measurementType: "offlineFile", executiveSummary: "Synthetic report for tests.", measurementSetup: ["signal": "chirp", "sample_rate_hertz": "48000"], devices: [device], signalConfiguration: ["seed": "42"], audioFormat: ["sample_rate_hertz": "48000"], runs: runs, statistics: nil, quality: runs.first?.quality, warnings: [], calibration: ReportCalibration(profileName: "Synthetic profile", method: "manualKnownDelay", knownDelaySamples: 12, confidence: 0.99, applied: true), drift: ReportDrift(relativePartsPerMillion: 10, constantOffsetSamples: 2, fitResidualRMS: 0.1, confidence: 0.8, nonLinearWarning: false, observations: [ReportDriftObservation(eventIndex: 0, expectedSample: 0, observedSample: 2, errorSamples: 2, timeSeconds: 0)]), charts: [chart], processingLog: [], appVersion: "test", algorithmVersion: "synthetic-v1", reproducibility: ["seed": "42"], notes: "Synthetic only.", privacy: ReportPrivacyOptions())
    }
}
