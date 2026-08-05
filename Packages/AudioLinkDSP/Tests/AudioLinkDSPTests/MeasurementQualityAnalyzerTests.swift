import AudioLinkCore
import Foundation
import Testing
@testable import AudioLinkDSP

@Test func cleanMeasurementIsExcellentOrGoodAndExplainsItsScore() async throws {
    let fixture = try cleanQualityFixture()
    let result = try await MeasurementQualityAnalyzer().analyze(
        reference: fixture.reference,
        observed: fixture.observed,
        correlationConfiguration: fixture.configuration
    )

    #expect(result.delay?.sampleOffset.rawValue == 500)
    #expect([MeasurementQualityLevel.excellent, .good].contains(result.quality.level))
    #expect(result.quality.confidence.value >= 0.7)
    #expect(!result.quality.confidence.components.isEmpty)
    #expect(abs(result.quality.confidence.components.reduce(0) { $0 + $1.weightedContribution } - result.quality.confidence.value) < 1e-12)
    #expect(!result.quality.shouldRemeasure)
    let codes = Set(result.quality.metrics.map(\.code))
    #expect(codes.isSuperset(of: [
        .primaryCorrelation, .primaryToSecondaryRatio, .peakToSidelobeRatio,
        .peakWidthSamples, .localPeakSharpness, .referenceRMS, .observedRMS,
        .signalToNoiseDecibels, .clippingRatio, .dcOffsetMagnitude,
        .referenceCoverageRatio, .searchBoundaryDistanceSamples,
        .invertedPolarity, .similarPeakCount, .truncationRatio
    ]))
}

@Test func lowAmplitudeDeterministicallyLowersQuality() async throws {
    let fixture = try cleanQualityFixture(observedGain: 0.01)
    let analyzer = MeasurementQualityAnalyzer()
    let quiet = try await analyzer.analyze(
        reference: fixture.reference,
        observed: fixture.observed,
        correlationConfiguration: fixture.configuration
    )
    let cleanFixture = try cleanQualityFixture()
    let clean = try await analyzer.analyze(
        reference: cleanFixture.reference,
        observed: cleanFixture.observed,
        correlationConfiguration: cleanFixture.configuration
    )

    #expect(quiet.quality.issues.contains { $0.code == .inputTooQuiet })
    #expect(quiet.quality.confidence.value < clean.quality.confidence.value)
    #expect(quiet.quality.level != .excellent)
    #expect(quiet.delay?.sampleOffset.rawValue == 500)
}

@Test func excessiveNoiseLowersQualityAndKeepsDiagnostics() async throws {
    let referenceSamples = qualityNoise(count: 2_048, seed: 11).map { $0 * 0.5 }
    var observed = [Float](repeating: 0, count: 400)
        + referenceSamples.map { $0 * 0.2 }
        + [Float](repeating: 0, count: 400)
    let noise = qualityNoise(count: observed.count, seed: 99)
    for index in observed.indices { observed[index] += noise[index] * 0.15 }
    let result = try await qualityAnalysis(
        reference: referenceSamples,
        observed: observed,
        search: SampleLagRange(minimum: 0, maximum: 800)
    )

    #expect(result.quality.issues.contains { $0.code == .excessiveNoise })
    #expect([MeasurementQualityLevel.questionable, .poor].contains(result.quality.level))
    #expect(result.quality.signal.signalToNoiseDecibels ?? 100 < 20)
    #expect(result.quality.metrics.contains { $0.code == .signalToNoiseDecibels })
}

@Test func clippingIsDetectedAndCannotReceiveGoodQuality() async throws {
    let reference = qualityNoise(count: 2_048, seed: 12).map { $0 * 0.7 }
    let clippedSignal = reference.map { max(-1, min(1, $0 * 3)) }
    let observed = [Float](repeating: 0, count: 200) + clippedSignal + [Float](repeating: 0, count: 200)
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: 0, maximum: 400)
    )

    #expect(result.quality.issues.contains { $0.code == .clippingDetected })
    #expect(result.quality.signal.clippingRatio > MeasurementQualityThresholds.standard.clippingSevereRatio)
    #expect([MeasurementQualityLevel.poor, .invalid].contains(result.quality.level))
    #expect(result.quality.shouldRemeasure)
}

@Test func repeatedSignalsExposeCandidatesAndPeriodicAmbiguity() async throws {
    let reference = qualityNoise(count: 512, seed: 13).map { $0 * 0.5 }
    var observed = [Float](repeating: 0, count: 2_400)
    for start in [300, 1_000, 1_700] {
        observed.replaceSubrange(start..<(start + reference.count), with: reference)
    }
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: 0, maximum: 1_888)
    )

    #expect(result.delay != nil)
    #expect(result.quality.peakAmbiguity.hasSimilarPeaks)
    #expect(result.quality.peakAmbiguity.candidates.count >= 3)
    #expect(result.quality.peakAmbiguity.periodicInterval?.rawValue == 700)
    #expect(result.quality.issues.contains { $0.code == .ambiguousPeak })
    #expect(result.quality.issues.contains { $0.code == .periodicPeakPattern })
    #expect(result.quality.level == .questionable)
}

@Test func searchEdgePeakProducesExplicitWarning() async throws {
    let reference = qualityNoise(count: 1_024, seed: 14).map { $0 * 0.4 }
    let observed = [Float](repeating: 0, count: 100) + reference + [Float](repeating: 0, count: 100)
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: 100, maximum: 300)
    )

    #expect(result.delay?.sampleOffset.rawValue == 100)
    #expect(result.quality.issues.contains { $0.code == .peakAtSearchBoundary })
    #expect(result.quality.delayDiagnostics.searchBoundaryDistance?.rawValue == 0)
    #expect(result.quality.shouldRemeasure)
}

@Test func invertedPolarityRemainsAValidSignal() async throws {
    let reference = qualityNoise(count: 2_048, seed: 15).map { $0 * 0.4 }
    let observed = [Float](repeating: 0, count: 333) + reference.map(-) + [Float](repeating: 0, count: 300)
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: 0, maximum: 700)
    )

    #expect(result.delay?.sampleOffset.rawValue == 333)
    #expect(result.correlation?.normalizedPeak ?? 0 < -0.999)
    #expect(result.quality.signal.isPolarityInverted == true)
    #expect(result.quality.issues.contains { $0.code == .polarityInverted })
    #expect(!result.quality.issues.contains { $0.code == .inputTooQuiet })
    #expect(result.quality.level != .invalid)
}

@Test func truncatedReferenceIsDetectedFromCoverage() async throws {
    let reference = qualityNoise(count: 2_048, seed: 16).map { $0 * 0.5 }
    let observed = Array(reference.dropFirst(650))
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: -900, maximum: 0),
        minimumOverlapRatio: 0.5
    )

    #expect(result.delay?.sampleOffset.rawValue == -650)
    #expect(result.quality.signal.referenceCoverageRatio ?? 1 < 0.8)
    #expect(result.quality.signal.appearsTruncated)
    #expect(result.quality.issues.contains { $0.code == .referencePartiallyMissing })
    #expect(result.quality.issues.contains { $0.code == .possibleTruncation })
    #expect(result.quality.level == .poor)
}

@Test func silenceIsInvalidAndNeverReturnsAPreciseDelay() async throws {
    let reference = [Float](repeating: 0, count: 2_048)
    let observed = [Float](repeating: 0, count: 4_096)
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: 0, maximum: 2_000)
    )

    #expect(result.delay == nil)
    #expect(result.correlation == nil)
    #expect(result.quality.level == .invalid)
    #expect(result.quality.confidence.value == 0)
    #expect(result.quality.issues.contains { $0.code == .inputTooQuiet && $0.severity == .fatal })
}

@Test func unrelatedNonSilentAudioIsInvalidInsteadOfReportingRandomDelay() async throws {
    let reference = qualityNoise(count: 2_048, seed: 501).map { $0 * 0.4 }
    let observed = qualityNoise(count: 8_192, seed: 777).map { $0 * 0.4 }
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: 0, maximum: 6_000)
    )

    #expect(result.delay == nil)
    #expect(result.quality.level == .invalid)
    #expect(result.quality.issues.contains { $0.code == .weakCorrelationPeak && $0.severity == .fatal })
    #expect(result.correlation != nil)
}

@Test func dcOffsetIsMeasuredAndExplained() async throws {
    let reference = qualityNoise(count: 2_048, seed: 502).map { $0 * 0.35 }
    let shifted = reference.map { $0 * 0.6 + 0.12 }
    let observed = [Float](repeating: 0.12, count: 300) + shifted + [Float](repeating: 0.12, count: 300)
    let result = try await qualityAnalysis(
        reference: reference,
        observed: observed,
        search: SampleLagRange(minimum: 0, maximum: 600)
    )

    #expect(result.quality.signal.dcOffsetMagnitude > 0.1)
    #expect(result.quality.issues.contains { $0.code == .dcOffsetDetected })
    #expect(result.quality.metrics.contains { $0.code == .dcOffsetMagnitude })
}

@Test func stereoDelayDisagreementProducesAnError() async throws {
    let referenceChannel = qualityNoise(count: 1_024, seed: 17).map { $0 * 0.4 }
    let reference = referenceChannel + referenceChannel
    let first = [Float](repeating: 0, count: 100) + referenceChannel + [Float](repeating: 0, count: 100)
    let second = [Float](repeating: 0, count: 130) + referenceChannel + [Float](repeating: 0, count: 70)
    let observed = first + second
    let referenceFile = try qualityImported(reference, channels: 2, name: "stereo-reference.wav")
    let observedFile = try qualityImported(observed, channels: 2, name: "stereo-observed.wav")
    let result = try await MeasurementQualityAnalyzer().analyze(
        reference: referenceFile,
        observed: observedFile,
        correlationConfiguration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: 0, maximum: 200),
            sequenceOutput: .none,
            minimumOverlapRatio: 1,
            channel: 0
        )
    )

    #expect(result.delay?.sampleOffset.rawValue == 100)
    #expect(result.quality.signal.channelsConsistent == false)
    #expect(result.quality.signal.channelDelaySpreadSamples ?? 0 > 20)
    #expect(result.quality.issues.contains { $0.code == .channelsDisagree && $0.severity == .error })
    #expect(result.quality.level == .poor)
    #expect(result.quality.delayDiagnostics.channelResults.count == 2)
}

@Test func scoreIsStableAndUnrelatedMetadataDoesNotAffectIt() async throws {
    let fixture = try cleanQualityFixture()
    let analyzer = MeasurementQualityAnalyzer()
    let first = try await analyzer.analyze(
        reference: fixture.reference,
        observed: fixture.observed,
        correlationConfiguration: fixture.configuration
    )
    let observedWithMetadata = ImportedAudioFile(
        fileURL: URL(fileURLWithPath: "/tmp/different-name.wav"),
        fileName: "different-name.wav",
        originalFormat: fixture.observed.originalFormat,
        audio: fixture.observed.audio,
        analysis: fixture.observed.analysis,
        metadata: ["artist": "Unrelated", "comment": "Must not alter DSP"],
        preprocessingLog: fixture.observed.preprocessingLog
    )
    let second = try await analyzer.analyze(
        reference: fixture.reference,
        observed: observedWithMetadata,
        correlationConfiguration: fixture.configuration
    )
    let third = try await analyzer.analyze(
        reference: fixture.reference,
        observed: fixture.observed,
        correlationConfiguration: fixture.configuration
    )

    #expect(first.quality == second.quality)
    #expect(first.quality == third.quality)
    #expect(first.delay == second.delay)
}

@Test func explicitResamplingIsReportedWithoutChangingPeakMath() async throws {
    let fixture = try cleanQualityFixture()
    let resampleLog = PreprocessingLogEntry(
        sequence: 0,
        operation: .resampled(
            sourceSampleRate: .hz44100,
            destinationSampleRate: .hz48000,
            inputFrames: fixture.observed.frameCount,
            outputFrames: fixture.observed.frameCount
        ),
        inputFrameCount: fixture.observed.frameCount,
        outputFrameCount: fixture.observed.frameCount
    )
    let logged = ImportedAudioFile(
        fileURL: fixture.observed.fileURL,
        fileName: fixture.observed.fileName,
        originalFormat: fixture.observed.originalFormat,
        audio: fixture.observed.audio,
        analysis: fixture.observed.analysis,
        preprocessingLog: [resampleLog]
    )
    let result = try await MeasurementQualityAnalyzer().analyze(
        reference: fixture.reference,
        observed: logged,
        correlationConfiguration: fixture.configuration
    )

    #expect(result.delay?.sampleOffset.rawValue == 500)
    #expect(result.quality.issues.contains { $0.code == .sampleRateConverted && $0.severity == .information })
}

@Test func formatterProducesStructuredUIContentWithoutSwiftUI() async throws {
    let fixture = try cleanQualityFixture(observedGain: 0.01)
    let result = try await MeasurementQualityAnalyzer().analyze(
        reference: fixture.reference,
        observed: fixture.observed,
        correlationConfiguration: fixture.configuration
    )
    let presentation = MeasurementQualityFormatter().presentation(for: result.quality)

    #expect(presentation.level == result.quality.level)
    #expect(!presentation.title.isEmpty)
    #expect(!presentation.summary.isEmpty)
    #expect(presentation.scoreText.hasSuffix("%"))
    #expect(!presentation.keyMetrics.isEmpty)
    #expect(presentation.warnings.contains { $0.code == .inputTooQuiet })
    #expect(!presentation.recommendations.isEmpty)
    #expect(result.quality.issues.allSatisfy {
        !$0.userDescription.isEmpty && !$0.technicalDescription.isEmpty && !$0.recommendedAction.isEmpty
    })
}

@Test func thresholdsAndQualityResultRoundTripThroughJSON() async throws {
    let thresholds = MeasurementQualityThresholds.standard
    #expect(try JSONDecoder().decode(
        MeasurementQualityThresholds.self,
        from: JSONEncoder().encode(thresholds)
    ) == thresholds)
    let fixture = try cleanQualityFixture()
    let result = try await MeasurementQualityAnalyzer().analyze(
        reference: fixture.reference,
        observed: fixture.observed,
        correlationConfiguration: fixture.configuration
    )
    let decoded = try JSONDecoder().decode(
        QualityAssessedMeasurement.self,
        from: JSONEncoder().encode(result)
    )
    #expect(decoded == result)
    #expect(result.quality.issues.allSatisfy {
        !$0.userDescription.isEmpty && !$0.technicalDescription.isEmpty && !$0.recommendedAction.isEmpty
    })
}

@Test func qualityAnalysisSupportsStructuredCancellation() async throws {
    let reference = try qualityImported(
        qualityNoise(count: 400_000, seed: 900).map { $0 * 0.3 },
        name: "cancel-reference.wav"
    )
    let observed = try qualityImported(
        qualityNoise(count: 800_000, seed: 901).map { $0 * 0.3 },
        name: "cancel-observed.wav"
    )
    let task = Task {
        try await MeasurementQualityAnalyzer().analyze(
            reference: reference,
            observed: observed,
            correlationConfiguration: CorrelationConfiguration(
                method: .fft,
                searchRange: SampleLagRange(minimum: 0, maximum: 100_000),
                sequenceOutput: .none,
                minimumOverlapRatio: 1
            )
        )
    }
    task.cancel()
    await #expect(throws: CorrelationAnalysisError.cancelled) {
        try await task.value
    }
}

@Test func invalidQualityThresholdPolicyIsRejected() async throws {
    var thresholds = MeasurementQualityThresholds.standard
    thresholds.maximumPeakCandidates = 0
    let fixture = try cleanQualityFixture()
    await #expect(throws: MeasurementQualityError.self) {
        try await MeasurementQualityAnalyzer().analyze(
            reference: fixture.reference,
            observed: fixture.observed,
            correlationConfiguration: fixture.configuration,
            thresholds: thresholds
        )
    }
}

private struct CleanQualityFixture {
    let reference: ImportedAudioFile
    let observed: ImportedAudioFile
    let configuration: CorrelationConfiguration
}

private func cleanQualityFixture(observedGain: Float = 0.6) throws -> CleanQualityFixture {
    let referenceSamples = qualityNoise(count: 2_048, seed: 10).map { $0 * 0.45 }
    let observedSamples = [Float](repeating: 0, count: 500)
        + referenceSamples.map { $0 * observedGain }
        + [Float](repeating: 0, count: 500)
    return CleanQualityFixture(
        reference: try qualityImported(referenceSamples, name: "reference.wav"),
        observed: try qualityImported(observedSamples, name: "observed.wav"),
        configuration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: 0, maximum: 1_000),
            sequenceOutput: .none,
            minimumOverlapRatio: 1
        )
    )
}

private func qualityAnalysis(
    reference: [Float],
    observed: [Float],
    search: SampleLagRange,
    minimumOverlapRatio: Double = 1
) async throws -> QualityAssessedMeasurement {
    try await MeasurementQualityAnalyzer().analyze(
        reference: qualityImported(reference, name: "reference.wav"),
        observed: qualityImported(observed, name: "observed.wav"),
        correlationConfiguration: CorrelationConfiguration(
            method: .fft,
            searchRange: search,
            sequenceOutput: .none,
            minimumOverlapRatio: minimumOverlapRatio
        )
    )
}

private func qualityImported(
    _ samples: [Float],
    channels: Int = 1,
    name: String,
    metadata: [String: String] = [:]
) throws -> ImportedAudioFile {
    let buffer = try AudioSampleBuffer(
        samples: samples,
        format: AudioFormatDescriptor(
            sampleRate: .hz48000,
            channelCount: channels,
            bitDepth: 32,
            isInterleaved: false
        )
    )
    return ImportedAudioFile(
        fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
        fileName: name,
        originalFormat: AudioFileFormatDescription(
            container: .wav,
            encoding: .ieeeFloat,
            sampleRate: .hz48000,
            channelCount: channels,
            bitDepth: 32,
            isInterleaved: true,
            isBigEndian: false,
            formatIdentifier: "WAVE_FORMAT_IEEE_FLOAT"
        ),
        audio: buffer,
        analysis: AudioMetricsAnalyzer().analyze(buffer),
        metadata: metadata
    )
}

private func qualityNoise(count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Double(state & 0x00FF_FFFF) / Double(0x0080_0000) - 1)
    }
}
