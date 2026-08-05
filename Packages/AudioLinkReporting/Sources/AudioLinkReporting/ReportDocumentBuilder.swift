import AudioLinkCore
import AudioLinkStorage
import Foundation

/// Converts the storage model to the deliberately smaller public report model.
/// This is the privacy boundary: bookmarks, absolute paths and opaque database
/// payloads are never copied into a report.
public enum ReportDocumentBuilder {
    public static func make(
        session: MeasurementHistorySession,
        privacy: ReportPrivacyOptions = ReportPrivacyOptions(),
        chapters: ReportChapterSelection = ReportChapterSelection(),
        charts: [ReportChart] = [],
        generatedAt: Date = Date()
    ) -> ReportDocument {
        let runs = session.runs.map { makeRun($0, privacy: privacy) }
        let first = runs.first
        let allWarnings = uniqueWarnings(runs.flatMap { $0.warnings })
        let setup = session.configurationSummary
        let format = first.map { [
            "sample_rate_hertz": String($0.reference.sampleRateHertz),
            "reference_channels": String($0.reference.channelCount),
            "recording_channels": String($0.recording.channelCount),
            "reference_frames": String($0.reference.frameCount),
            "recording_frames": String($0.recording.frameCount)
        ] } ?? [:]
        let devices = deviceSummaries(session: session, privacy: privacy)
        let quality = first?.quality
        let calibration = first?.calibration
        let drift = first?.drift
        let title = session.name.isEmpty ? "AudioLink Lab Measurement Report" : session.name

        return ReportDocument(
            title: title,
            generatedAt: generatedAt,
            sessionID: session.id,
            measurementType: session.measurementType.rawValue,
            executiveSummary: chapters.executiveSummary ? summary(session: session, firstRun: first) : "",
            measurementSetup: chapters.measurementSetup ? setup : [:],
            devices: chapters.deviceInformation ? devices : [],
            signalConfiguration: chapters.signalConfiguration ? setup : [:],
            audioFormat: chapters.audioFormat ? format : [:],
            runs: runs,
            statistics: chapters.statisticalSummary ? makeStatistics(session, runs: runs) : nil,
            quality: chapters.qualityAndConfidence ? quality : nil,
            warnings: chapters.warnings ? allWarnings : [],
            calibration: chapters.calibration ? calibration : nil,
            drift: chapters.drift ? drift : nil,
            charts: chapters.charts ? charts : [],
            processingLog: chapters.processingLog ? runs.flatMap(\.processingLog) : [],
            appVersion: chapters.versions ? session.appVersion : "",
            algorithmVersion: chapters.versions ? session.algorithmVersion : "",
            reproducibility: chapters.reproducibility ? reproducibility(session: session, firstRun: first) : [:],
            notes: chapters.notes ? session.notes.nilIfEmpty : nil,
            privacy: privacy
        )
    }

    public static func make(
        run: MeasurementHistoryRun,
        session: MeasurementHistorySession? = nil,
        privacy: ReportPrivacyOptions = ReportPrivacyOptions(),
        chapters: ReportChapterSelection = ReportChapterSelection(),
        charts: [ReportChart] = [],
        appVersion: String = "",
        algorithmVersion: String = "",
        generatedAt: Date = Date()
    ) -> ReportDocument {
        let reportRun = makeRun(run, privacy: privacy)
        let setup = session?.configurationSummary ?? [:]
        let title = session?.name ?? "AudioLink Lab Measurement Run"
        let devices = session.map { deviceSummaries(session: $0, privacy: privacy) } ?? []
        return ReportDocument(
            title: title,
            generatedAt: generatedAt,
            sessionID: session?.id ?? run.sessionID,
            measurementType: session?.measurementType.rawValue ?? "offlineFile",
            executiveSummary: chapters.executiveSummary ? "Measurement run \(run.id.uuidString) with \(reportRun.quality.level) quality." : "",
            measurementSetup: chapters.measurementSetup ? setup : [:],
            devices: chapters.deviceInformation ? devices : [],
            signalConfiguration: chapters.signalConfiguration ? setup : [:],
            audioFormat: chapters.audioFormat ? [
                "sample_rate_hertz": String(reportRun.reference.sampleRateHertz),
                "reference_channels": String(reportRun.reference.channelCount),
                "recording_channels": String(reportRun.recording.channelCount)
            ] : [:],
            runs: [reportRun],
            statistics: chapters.statisticalSummary ? makeStatistics(run.statistics, sampleRate: run.delayEstimate?.sampleRate ?? run.referenceFile.format.sampleRate) : nil,
            quality: chapters.qualityAndConfidence ? reportRun.quality : nil,
            warnings: chapters.warnings ? reportRun.warnings : [],
            calibration: chapters.calibration ? reportRun.calibration : nil,
            drift: chapters.drift ? reportRun.drift : nil,
            charts: chapters.charts ? charts : [],
            processingLog: chapters.processingLog ? reportRun.processingLog : [],
            appVersion: chapters.versions ? session?.appVersion ?? appVersion : "",
            algorithmVersion: chapters.versions ? session?.algorithmVersion ?? algorithmVersion : "",
            reproducibility: chapters.reproducibility ? session.map { reproducibility(session: $0, firstRun: reportRun) } ?? [:] : [:],
            notes: chapters.notes ? (session?.notes.nilIfEmpty ?? run.notes.nilIfEmpty) : nil,
            privacy: privacy
        )
    }

    private static func makeRun(_ run: MeasurementHistoryRun, privacy: ReportPrivacyOptions) -> ReportRun {
        let raw = run.calibration?.rawDelay ?? run.delayEstimate
        let sampleRate = raw?.sampleRate.hertz ?? run.referenceFile.format.sampleRate.hertz
        let delay = ReportDelay(
            integerSamples: raw?.sampleOffset.rawValue,
            fractionalSamples: raw?.fractionalSampleOffset,
            milliseconds: raw.map { $0.fractionalMilliseconds },
            sampleRateHertz: sampleRate,
            peakCorrelation: run.correlation?.primaryPeak?.value ?? run.correlation?.normalizedPeak,
            peakToSidelobeRatio: run.correlation?.peakToSidelobeRatio ?? raw?.peakToSidelobeRatio,
            confidence: raw?.confidence ?? run.correlation?.confidence,
            polarity: polarity(for: run.correlation?.primaryPeak?.value),
            calibratedMilliseconds: run.calibration?.calibratedDelay?.fractionalMilliseconds,
            calibrationOffsetSamples: run.calibration?.offset.sampleCount.rawValue
        )
        let warnings = run.quality.issues.map(makeWarning)
        let candidatePeaks = run.quality.delayDiagnostics.candidatePeaks.map { $0.lag.rawValue }
        var metricValues: [String: Double] = [:]
        for metric in run.quality.metrics where metric.value.isFinite {
            metricValues[metric.code.rawValue] = metric.value
        }
        let quality = ReportQuality(
            level: run.quality.level.rawValue,
            confidence: run.quality.confidence.value,
            summary: run.quality.summary,
            metrics: metricValues,
            issues: warnings,
            candidatePeakSamples: candidatePeaks,
            shouldRemeasure: run.quality.shouldRemeasure
        )
        let calibration = run.calibration.map {
            ReportCalibration(
                profileName: "Calibration \($0.profileID.uuidString.prefix(8))",
                method: "storedOffset",
                knownDelaySamples: $0.offset.sampleCount.rawValue,
                confidence: raw?.confidence ?? 0,
                applied: $0.offsetApplied,
                notes: nil
            )
        }
        return ReportRun(
            id: run.id,
            sessionID: run.sessionID,
            createdAt: run.createdAt,
            completedAt: run.completedAt,
            reference: makeFile(run.referenceFile, privacy: privacy),
            recording: makeFile(run.recordingFile, privacy: privacy),
            delay: delay,
            quality: quality,
            statistics: makeStatistics(run.statistics, sampleRate: raw?.sampleRate ?? run.referenceFile.format.sampleRate),
            calibration: calibration,
            drift: nil,
            warnings: warnings,
            processingLog: run.processingSteps.map(makeProcessingStep),
            chartCache: [
                "correlation_sequence_available": String(run.chartCache.correlationSequenceAvailable),
                "waveform_available": String(run.chartCache.waveformAvailable),
                "waveform_unavailable_reason": run.chartCache.waveformUnavailableReason ?? ""
            ],
            notes: run.notes
        )
    }

    private static func makeFile(_ file: StoredAudioFileMetadata, privacy: ReportPrivacyOptions) -> ReportAudioFile {
        ReportAudioFile(
            role: file.role.rawValue,
            fileName: file.fileName,
            container: file.container,
            encoding: file.encoding,
            sampleRateHertz: file.format.sampleRate.hertz,
            channelCount: file.format.channelCount,
            bitDepth: file.format.bitDepth,
            interleaved: file.format.isInterleaved,
            frameCount: file.frameCount,
            durationSeconds: file.durationSeconds,
            peak: file.peakMagnitude,
            rms: file.rootMeanSquare,
            clippingSampleCount: file.clippingSampleCount,
            dcOffset: file.dcOffset,
            anonymousIdentifier: privacy.includeDetailedDiagnosticIdentifiers ? file.privacyIdentifier : nil
        )
    }

    private static func deviceSummaries(session: MeasurementHistorySession, privacy: ReportPrivacyOptions) -> [ReportDevice] {
        var result: [ReportDevice] = []
        if let input = session.inputDevice {
            result.append(makeDevice(input, role: "input", privacy: privacy))
        }
        if let output = session.outputDevice {
            result.append(makeDevice(output, role: "output", privacy: privacy))
        }
        return result
    }

    private static func makeDevice(_ device: DeviceDescriptor, role: String, privacy: ReportPrivacyOptions) -> ReportDevice {
        ReportDevice(
            role: role,
            name: device.name,
            manufacturer: device.manufacturer,
            transport: device.transport.rawValue,
            supportsInput: device.supportsInput,
            supportsOutput: device.supportsOutput,
            diagnosticIdentifier: privacy.includeDetailedDiagnosticIdentifiers ? device.id : nil
        )
    }

    private static func makeWarning(_ issue: QualityIssue) -> ReportWarning {
        ReportWarning(
            id: issue.code.rawValue,
            severity: issue.severity.rawValue,
            title: issue.code.rawValue,
            detail: issue.userDescription + " " + issue.technicalDescription,
            recommendation: issue.recommendedAction
        )
    }

    private static func makeProcessingStep(_ step: StoredProcessingStep) -> ReportProcessingStep {
        ReportProcessingStep(role: step.role.rawValue, sequence: step.sequence, operation: step.operationCode, summary: step.summary, inputFrames: step.inputFrameCount, outputFrames: step.outputFrameCount)
    }

    private static func makeStatistics(_ session: MeasurementHistorySession, runs: [ReportRun]) -> ReportStatistics? {
        if let repeated = session.repeatedStatistics { return makeStatistics(repeated) }
        guard let stats = session.statistics else { return nil }
        let sampleRate = runs.first?.delay.sampleRateHertz ?? 48_000
        return makeStatistics(stats, sampleRate: try? SampleRate(hertz: sampleRate))
    }

    private static func makeStatistics(_ stats: MeasurementStatistics?, sampleRate: SampleRate?) -> ReportStatistics? {
        guard let stats else { return nil }
        let rate = sampleRate?.hertz ?? 48_000
        func milliseconds(_ samples: SampleCount) -> Double {
            Double(samples.rawValue) / rate * 1_000
        }
        return ReportStatistics(
            outcomeCount: stats.sampleSize,
            successCount: stats.sampleSize,
            failureCount: 0,
            populationCount: stats.sampleSize,
            includesMarkedOutliers: true,
            minimumMilliseconds: milliseconds(stats.minimumDelay),
            maximumMilliseconds: milliseconds(stats.maximumDelay),
            meanMilliseconds: milliseconds(stats.meanDelay),
            medianMilliseconds: milliseconds(stats.medianDelay),
            varianceMillisecondsSquared: nil,
            jitterStandardDeviationMilliseconds: stats.jitterStandardDeviation.milliseconds,
            p50Milliseconds: milliseconds(stats.medianDelay),
            p90Milliseconds: nil,
            p95Milliseconds: nil,
            p99Milliseconds: nil,
            peakToPeakJitterMilliseconds: milliseconds(stats.maximumDelay) - milliseconds(stats.minimumDelay),
            medianAbsoluteDeviationMilliseconds: nil,
            interquartileRangeMilliseconds: nil,
            confidenceIntervalLowMilliseconds: nil,
            confidenceIntervalHighMilliseconds: nil,
            outlierMethod: nil,
            outlierThreshold: nil,
            qualityDistribution: [:]
        )
    }

    private static func makeStatistics(_ stats: RepeatedMeasurementStatistics?) -> ReportStatistics? {
        guard let stats else { return nil }
        let interval = stats.confidenceInterval
        let distribution = [
            "excellent": stats.qualityDistribution.excellent,
            "good": stats.qualityDistribution.good,
            "questionable": stats.qualityDistribution.questionable,
            "poor": stats.qualityDistribution.poor,
            "invalid": stats.qualityDistribution.invalid
        ]
        return ReportStatistics(
            outcomeCount: stats.outcomeCount,
            successCount: stats.successCount,
            failureCount: stats.failureCount,
            populationCount: stats.populationCount,
            includesMarkedOutliers: stats.includesMarkedOutliers,
            minimumMilliseconds: stats.minimumMilliseconds,
            maximumMilliseconds: stats.maximumMilliseconds,
            meanMilliseconds: stats.meanMilliseconds,
            medianMilliseconds: stats.medianMilliseconds,
            varianceMillisecondsSquared: stats.varianceMillisecondsSquared,
            jitterStandardDeviationMilliseconds: stats.jitterStandardDeviationMilliseconds,
            p50Milliseconds: stats.percentile50Milliseconds,
            p90Milliseconds: stats.percentile90Milliseconds,
            p95Milliseconds: stats.percentile95Milliseconds,
            p99Milliseconds: stats.percentile99Milliseconds,
            peakToPeakJitterMilliseconds: stats.peakToPeakJitterMilliseconds,
            medianAbsoluteDeviationMilliseconds: stats.medianAbsoluteDeviationMilliseconds,
            interquartileRangeMilliseconds: stats.interquartileRangeMilliseconds,
            confidenceIntervalLowMilliseconds: interval?.lowerBoundMilliseconds,
            confidenceIntervalHighMilliseconds: interval?.upperBoundMilliseconds,
            outlierMethod: stats.outlierMethod.rawValue,
            outlierThreshold: stats.outlierThreshold,
            qualityDistribution: distribution
        )
    }

    private static func summary(session: MeasurementHistorySession, firstRun: ReportRun?) -> String {
        guard let firstRun else { return "No completed measurement runs are present in this session." }
        let delay = firstRun.delay.calibratedMilliseconds ?? firstRun.delay.milliseconds
        let delayText = delay.map { String(format: "%.3f ms", $0) } ?? "unavailable"
        return "\(session.runs.count) run(s); estimated delay \(delayText); quality \(firstRun.quality.level)."
    }

    private static func reproducibility(session: MeasurementHistorySession, firstRun: ReportRun?) -> [String: String] {
        var result = session.configurationSummary
        result["app_version"] = session.appVersion
        result["algorithm_version"] = session.algorithmVersion
        if let firstRun {
            result["reference_sample_rate_hertz"] = String(firstRun.reference.sampleRateHertz)
            result["recording_sample_rate_hertz"] = String(firstRun.recording.sampleRateHertz)
        }
        return result
    }

    private static func polarity(for value: Double?) -> String? {
        guard let value else { return nil }
        return value < 0 ? "inverted" : "normal"
    }

    private static func uniqueWarnings(_ warnings: [ReportWarning]) -> [ReportWarning] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0.id).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
