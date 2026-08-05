import AudioLinkCore
import AudioLinkDSP
import AudioLinkReporting
import AudioLinkStorage
import Foundation

enum AppReportExportAdapters {
    static func document(for analysis: NewMeasurementAnalysis, privacy: ReportPrivacyOptions, chapters: ReportChapterSelection) -> ReportDocument {
        let sessionID = analysis.id
        let reference = storedFile(analysis.preparedReference, role: .reference)
        let recording = storedFile(analysis.preparedRecording, role: .recording)
        let run = MeasurementHistoryRun(
            id: analysis.id,
            sessionID: sessionID,
            createdAt: Date(),
            completedAt: Date(),
            referenceFile: reference,
            recordingFile: recording,
            delayEstimate: analysis.assessment.delay,
            calibration: analysis.assessment.calibration,
            correlation: analysis.assessment.correlation,
            quality: analysis.assessment.quality,
            processingSteps: storedSteps(analysis.preparedReference, role: .reference) + storedSteps(analysis.preparedRecording, role: .recording),
            chartCache: StoredChartCacheMetadata(
                correlationSequenceAvailable: analysis.assessment.correlation?.sequence?.values.isEmpty == false,
                correlationSampleCount: analysis.assessment.correlation?.sequence?.values.count ?? 0,
                waveformAvailable: true
            )
        )
        let charts = charts(for: analysis)
        return ReportDocumentBuilder.make(
            run: run,
            privacy: privacy,
            chapters: chapters,
            charts: charts,
            appVersion: AudioLinkReleaseMetadata.appVersion,
            algorithmVersion: AudioLinkReleaseMetadata.algorithmVersion
        )
    }

    private static func storedFile(_ file: ImportedAudioFile, role: StoredFileRole) -> StoredAudioFileMetadata {
        StoredAudioFileMetadata(
            role: role,
            privacyIdentifier: UUID().uuidString,
            fileName: file.fileName,
            container: file.originalFormat.container.rawValue,
            encoding: file.originalFormat.encoding.rawValue,
            format: file.internalFormat,
            frameCount: file.frameCount,
            durationSeconds: file.duration.value,
            peakMagnitude: Double(file.peakMagnitude),
            rootMeanSquare: Double(file.rootMeanSquare),
            clippingSampleCount: file.clippingSampleCount,
            dcOffset: Double(file.dcOffset)
        )
    }

    private static func storedSteps(_ file: ImportedAudioFile, role: StoredFileRole) -> [StoredProcessingStep] {
        file.preprocessingLog.map { entry in
            StoredProcessingStep(role: role, sequence: entry.sequence, operationCode: entry.operation.summary, summary: entry.operation.summary, inputFrameCount: entry.inputFrameCount, outputFrameCount: entry.outputFrameCount)
        }
    }

    private static func charts(for analysis: NewMeasurementAnalysis) -> [ReportChart] {
        guard let sequence = analysis.assessment.correlation?.sequence,
              !sequence.values.isEmpty else { return [] }
        let rate = analysis.assessment.delay?.sampleRate.hertz ?? analysis.preparedReference.sampleRate.hertz
        let stride = max(1, sequence.values.count / 2_000)
        let points = Swift.stride(from: 0, to: sequence.values.count, by: stride).map { index in
            ReportPoint(x: Double(sequence.firstLag + Int64(index)) / rate * 1_000, y: Double(sequence.values[index]), xUnit: "milliseconds", yUnit: "correlation")
        }
        let marker = analysis.assessment.delay.map { ReportChartMarker(label: "primary peak", x: Double($0.sampleOffset.rawValue) / rate * 1_000, y: $0.peakAmplitude) }
        return [ReportChart(id: "cross-correlation", title: "Cross-Correlation", kind: "correlation", points: points, markers: marker.map { [$0] } ?? [], xLabel: "Lag (ms)", yLabel: "Correlation")]
    }
}
