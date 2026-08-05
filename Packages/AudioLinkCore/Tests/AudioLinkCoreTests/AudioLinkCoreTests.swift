import Foundation
import Testing
@testable import AudioLinkCore

@Test func unitConversionsAreExplicitAndReversible() throws {
    let rate = try SampleRate(hertz: 48_000)
    let samples = SampleCount(rawValue: 480)

    #expect(samples.duration(at: rate).milliseconds == 10)
    #expect(samples.duration(at: rate).sampleCount(at: rate) == samples)
    #expect(throws: UnitValidationError.self) { try SampleRate(hertz: 0) }
    #expect(throws: UnitValidationError.self) { try DurationSeconds(-1) }
}

@Test func calibrationPreservesRawDelayAndDerivesCorrectedDelayOnlyOnMatch() throws {
    let input = DeviceDescriptor(id: "in", name: "Input", supportsInput: true, supportsOutput: false)
    let output = DeviceDescriptor(id: "out", name: "Output", supportsInput: false, supportsOutput: true)
    let profile = CalibrationProfile(
        profileName: "Loopback",
        inputDevice: input,
        outputDevice: output,
        channelMapping: CalibrationChannelMapping(inputChannel: 0, outputChannel: 0),
        sampleRate: .hz48000,
        bufferFrameCount: 512,
        knownFixedDelay: CalibrationOffset(sampleCount: SampleCount(rawValue: 240), sampleRate: .hz48000),
        confidence: 0.9,
        calibrationMethod: .manualKnownDelay
    )
    let raw = DelayEstimate(sampleOffset: SampleCount(rawValue: 1_240), sampleRate: .hz48000, confidence: 0.8, fractionalSampleOffset: 1_240.25)
    let route = CalibrationRouteDescriptor(inputDeviceID: "in", outputDeviceID: "out", channelMapping: CalibrationChannelMapping(inputChannel: 0, outputChannel: 0), sampleRate: .hz48000, bufferFrameCount: 512)
    let result = try CalibrationApplicator.apply(rawDelay: raw, profile: profile, route: route)
    #expect(result.rawDelay == raw)
    #expect(result.calibratedDelay?.sampleOffset == SampleCount(rawValue: 1_000))
    #expect(result.calibratedDelay?.fractionalSampleOffset == 1_000.25)
    #expect(throws: CalibrationMatchFailure.self) {
        _ = try CalibrationApplicator.apply(rawDelay: raw, profile: profile, route: CalibrationRouteDescriptor(inputDeviceID: "other", outputDeviceID: "out", channelMapping: route.channelMapping, sampleRate: .hz48000, bufferFrameCount: 512))
    }
}

@Test func measurementSessionRoundTripsThroughJSON() throws {
    let runID = try #require(UUID(uuidString: "73A9844E-A973-42B5-A808-F26E6D8EF75E"))
    let sessionID = try #require(UUID(uuidString: "15003953-5B73-4E24-A6AA-4A6876D350FC"))
    let format = AudioFormatDescriptor(
        sampleRate: .hz48000,
        channelCount: 2,
        bitDepth: 32,
        isInterleaved: false
    )
    let configuration = MeasurementConfiguration(
        format: format,
        signal: .sineSweep,
        measurementDuration: try DurationSeconds(2),
        repetitions: 3
    )
    let correlation = CorrelationResult(
        peakOffset: SampleCount(rawValue: 240),
        normalizedPeak: 0.98,
        peakToSidelobeRatio: 12,
        confidence: 0.95,
        primaryPeak: CorrelationPeak(
            lag: SampleCount(rawValue: 240),
            fractionalLag: 240.25,
            value: 0.98,
            overlapCount: SampleCount(rawValue: 48_000)
        ),
        secondaryPeak: CorrelationPeak(
            lag: SampleCount(rawValue: 720),
            value: 0.08,
            overlapCount: SampleCount(rawValue: 47_520)
        ),
        sequence: CorrelationSequence(firstLag: 239, values: [0.8, 0.98, 0.7]),
        diagnostics: AnalysisDiagnostics(
            implementation: .fft,
            validity: .valid,
            validLagRange: SampleLagRange(minimum: -47_999, maximum: 95_999),
            searchedLagRange: SampleLagRange(minimum: 0, maximum: 48_000),
            searchRangeWasClamped: false,
            peakAtSearchBoundary: false,
            referenceRMS: 0.3,
            observedRMS: 0.2,
            minimumOverlapCount: SampleCount(rawValue: 24_000),
            fftLength: 262_144,
            estimatedWorkingSetBytes: 9_000_000,
            interpolationStatus: .applied
        )
    )
    let run = MeasurementRun(
        id: runID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: Date(timeIntervalSince1970: 1_700_000_001),
        delayEstimate: DelayEstimate(
            sampleOffset: SampleCount(rawValue: 240),
            sampleRate: .hz48000,
            confidence: 0.95,
            fractionalSampleOffset: 240.25,
            peakAmplitude: 0.98,
            peakToSidelobeRatio: 12,
            isReliable: true
        ),
        correlation: correlation
    )
    let session = MeasurementSession(
        id: sessionID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        name: "Loopback",
        configuration: configuration,
        runs: [run]
    )

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(MeasurementSession.self, from: data)
    #expect(decoded == session)
}

@Test func errorsKeepSeparateUserAndDebugDescriptions() throws {
    let error = MeasurementError.audioEngineFailure(
        ErrorContext(
            underlyingType: "ExampleOSStatusError",
            diagnosticMessage: "AudioUnit returned -10863",
            metadata: ["deviceID": "42"]
        )
    )

    #expect(error.userFacingDescription.contains("Audio"))
    #expect(error.debugContext.diagnosticMessage.contains("-10863"))
    let decoded = try JSONDecoder().decode(
        MeasurementError.self,
        from: JSONEncoder().encode(error)
    )
    #expect(decoded == error)
}

@Test func explainableMeasurementQualityRoundTripsThroughJSON() throws {
    let issue = QualityIssue(
        code: .ambiguousPeak,
        severity: .warning,
        userDescription: "Multiple delays are plausible.",
        technicalDescription: "Two local peaks differ by less than three percent.",
        recommendedAction: "Use a non-repeating reference signal."
    )
    let metric = QualityMetric(
        code: .primaryCorrelation,
        value: 0.9,
        unit: .coefficient,
        normalizedScore: 0.85,
        weight: 0.2,
        idealMinimum: 0.93,
        explanation: "Normalized coefficient at the selected lag."
    )
    let quality = MeasurementQuality(
        level: .questionable,
        confidence: ConfidenceScore(
            value: 0.69,
            components: [
                ConfidenceComponent(
                    metric: .primaryCorrelation,
                    normalizedScore: 0.85,
                    weight: 1,
                    weightedContribution: 0.69
                )
            ]
        ),
        summary: "More than one delay candidate is plausible.",
        metrics: [metric],
        issues: [issue],
        peakAmbiguity: PeakAmbiguity(
            candidates: [],
            primaryToSecondaryRatio: 1.02,
            hasSimilarPeaks: true,
            peakSpacings: [SampleCount(rawValue: 480)],
            periodicInterval: nil,
            explanation: "Two candidates are similar."
        ),
        signal: SignalQualityAnalysis(
            referenceRMS: 0.2,
            observedRMS: 0.1,
            signalToNoiseDecibels: 18,
            clippingRatio: 0,
            dcOffsetMagnitude: 0,
            referenceCoverageRatio: 1,
            isPolarityInverted: false,
            appearsTruncated: false,
            channelsConsistent: nil,
            channelDelaySpreadSamples: nil,
            channelPeakSpread: nil
        ),
        delayDiagnostics: DelayEstimateDiagnostics(
            selectedDelay: nil,
            candidatePeaks: [],
            peakWidthSamples: 2,
            localPeakSharpness: 0.4,
            searchBoundaryDistance: SampleCount(rawValue: 1_000),
            channelResults: []
        ),
        shouldRemeasure: true
    )

    let decoded = try JSONDecoder().decode(
        MeasurementQuality.self,
        from: JSONEncoder().encode(quality)
    )
    #expect(decoded == quality)
    #expect(decoded.confidence.components.first?.weightedContribution == 0.69)
    #expect(decoded.issues.first?.recommendedAction.contains("non-repeating") == true)

    let run = MeasurementRun(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        quality: quality
    )
    let decodedRun = try JSONDecoder().decode(
        MeasurementRun.self,
        from: JSONEncoder().encode(run)
    )
    #expect(decodedRun.quality == quality)
}
