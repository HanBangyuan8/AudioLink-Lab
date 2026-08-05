import AudioLinkCore
import Foundation
import Testing
@testable import AudioLinkDSP

@Test func integerDelaysAreSampleExactAcrossImplementations() async throws {
    let reference = deterministicCorrelationNoise(count: 2_048, seed: 0xA11D10)
    for delay in [0, 1, 10, 100, 1_000] {
        let observed = [Float](repeating: 0, count: delay) + reference + [Float](repeating: 0, count: 127)
        for method in [CorrelationMethod.direct, .fft] {
            let result = try await CorrelationEngine().correlate(
                reference: reference,
                observed: observed,
                configuration: CorrelationConfiguration(
                    method: method,
                    searchRange: SampleLagRange(minimum: -128, maximum: 1_128),
                    sequenceOutput: .none,
                    minimumOverlapRatio: 0.75
                )
            )
            #expect(result.peakOffset.rawValue == Int64(delay))
            #expect(result.normalizedPeak > 0.999_9)
            #expect(result.diagnostics?.validity == .valid)
        }
    }
}

@Test func negativeLagAndPartialTruncationFollowDocumentedConvention() async throws {
    let signal = deterministicCorrelationNoise(count: 1_024, seed: 17)
    let reference = [Float](repeating: 0, count: 200) + signal
    let observed = signal + [Float](repeating: 0, count: 200)
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: -300, maximum: 100),
            minimumOverlapRatio: 0.75
        )
    )

    #expect(result.peakOffset.rawValue == -200)
    #expect(result.normalizedPeak > 0.999_9)

    let truncatedObserved = Array(signal.dropFirst(160))
    let truncated = try await CorrelationEngine().correlate(
        reference: signal,
        observed: truncatedObserved,
        configuration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: -250, maximum: 0),
            minimumOverlapRatio: 0.75
        )
    )
    #expect(truncated.peakOffset.rawValue == -160)
}

@Test func directAndFFTCorrelationSequencesAgree() throws {
    let reference = deterministicCorrelationNoise(count: 257, seed: 91)
    let observed = deterministicCorrelationNoise(count: 63, seed: 42)
        + reference.map { $0 * 0.42 }
        + deterministicCorrelationNoise(count: 89, seed: 43)
    let configuration = CorrelationConfiguration(
        searchRange: SampleLagRange(minimum: -100, maximum: 420),
        sequenceOutput: .searchedRange,
        minimumOverlapRatio: 0.6
    )
    let direct = try CorrelationEngine().correlateSynchronously(
        reference: reference,
        observed: observed,
        configuration: overridingMethod(configuration, with: .direct)
    )
    let fft = try CorrelationEngine().correlateSynchronously(
        reference: reference,
        observed: observed,
        configuration: overridingMethod(configuration, with: .fft)
    )

    #expect(direct.peakOffset == fft.peakOffset)
    #expect(abs(direct.normalizedPeak - fft.normalizedPeak) < 2e-5)
    let directValues = try #require(direct.sequence?.values)
    let fftValues = try #require(fft.sequence?.values)
    #expect(directValues.count == fftValues.count)
    #expect(zip(directValues, fftValues).allSatisfy { abs($0 - $1) < 2e-5 })
}

@Test func fullLinearSequenceHasExpectedLagBounds() throws {
    let reference: [Float] = [0.25, -0.5, 1]
    let observed: [Float] = [0, 0.25, -0.5, 1, 0]
    let result = try CorrelationEngine().correlateSynchronously(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .fft,
            sequenceOutput: .full,
            minimumOverlapRatio: 1
        )
    )
    let sequence = try #require(result.sequence)
    #expect(sequence.firstLag == -2)
    #expect(sequence.lastLag == 4)
    #expect(sequence.values.count == reference.count + observed.count - 1)
    #expect(result.peakOffset.rawValue == 1)
}

@Test func directRawCorrelationMatchesTheDocumentedEquation() throws {
    let result = try CorrelationEngine().correlateSynchronously(
        reference: [1, 2],
        observed: [0, 1, 2],
        configuration: CorrelationConfiguration(
            method: .direct,
            normalization: .none,
            sequenceOutput: .full,
            minimumOverlapRatio: 0.5,
            interpolateSubsample: false,
            minimumPeakMagnitude: 0
        )
    )
    let sequence = try #require(result.sequence)
    #expect(sequence.firstLag == -1)
    #expect(sequence.values == [0, 2, 5, 2])
    #expect(result.peakOffset.rawValue == 1)
}

@Test func correlationConfigurationRoundTripsThroughJSON() throws {
    let configuration = CorrelationConfiguration(
        method: .fft,
        normalization: .overlapEnergy,
        searchRange: SampleLagRange(minimum: -100, maximum: 2_000),
        peakSelection: .negative,
        sequenceOutput: .full,
        minimumOverlapRatio: 0.7,
        directOperationLimit: 42_000,
        sidelobeExclusionRadius: 12,
        interpolateSubsample: false,
        minimumInputRMS: 1e-6,
        minimumPeakMagnitude: 0.3,
        minimumPeakToSidelobeRatio: 1.4,
        ambiguityTolerance: 0.01,
        channel: 1
    )
    let decoded = try JSONDecoder().decode(
        CorrelationConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )
    #expect(decoded == configuration)
}

@Test func requestedSearchRangeClampingIsExplicit() async throws {
    let reference = deterministicCorrelationNoise(count: 100, seed: 100)
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: reference,
        configuration: CorrelationConfiguration(
            method: .direct,
            searchRange: SampleLagRange(minimum: -1_000, maximum: 1_000),
            minimumOverlapRatio: 0.8
        )
    )
    #expect(result.diagnostics?.searchRangeWasClamped == true)
    #expect(result.diagnostics?.searchedLagRange == SampleLagRange(minimum: -20, maximum: 20))
}

@Test func normalizedCorrelationIsGainInvariantAndToleratesNoise() async throws {
    let reference = deterministicCorrelationNoise(count: 4_096, seed: 123)
    var observed = [Float](repeating: 0, count: 731)
        + reference.map { $0 * 0.18 }
        + [Float](repeating: 0, count: 211)
    let noise = deterministicCorrelationNoise(count: observed.count, seed: 999)
    for index in observed.indices {
        observed[index] += noise[index] * 0.01
    }
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: 0, maximum: 1_000),
            sequenceOutput: .none,
            minimumOverlapRatio: 1
        )
    )

    #expect(result.peakOffset.rawValue == 731)
    #expect(result.normalizedPeak > 0.98)
    #expect(result.diagnostics?.validity == .valid)
}

@Test func absoluteAndNegativePeakModesDetectInvertedSignal() async throws {
    let reference = deterministicCorrelationNoise(count: 1_024, seed: 55)
    let observed = [Float](repeating: 0, count: 73) + reference.map(-) + [Float](repeating: 0, count: 64)
    for selection in [CorrelationPeakSelection.absolute, .negative] {
        let result = try await CorrelationEngine().correlate(
            reference: reference,
            observed: observed,
            configuration: CorrelationConfiguration(
                method: .fft,
                searchRange: SampleLagRange(minimum: 0, maximum: 140),
                peakSelection: selection,
                minimumOverlapRatio: 1
            )
        )
        #expect(result.peakOffset.rawValue == 73)
        #expect(result.normalizedPeak < -0.999_9)
    }
}

@Test func repeatedReferenceIsReportedAsAmbiguous() async throws {
    let reference = deterministicCorrelationNoise(count: 512, seed: 8)
    var observed = [Float](repeating: 0, count: 2_000)
    for start in [200, 1_200] {
        observed.replaceSubrange(start..<(start + reference.count), with: reference)
    }
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: 0, maximum: 1_488),
            minimumOverlapRatio: 1
        )
    )

    #expect(result.secondaryPeak != nil)
    #expect(result.secondaryPeak?.magnitude ?? 0 > 0.999_9)
    #expect(result.diagnostics?.validity == .ambiguous)
    #expect(result.confidence <= 0.25)
}

@Test func unrelatedSignalDoesNotProduceFalseHighConfidence() async throws {
    let reference = deterministicCorrelationNoise(count: 2_048, seed: 1)
    let observed = deterministicCorrelationNoise(count: 8_192, seed: 2)
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: 0, maximum: 6_144),
            sequenceOutput: .none,
            minimumOverlapRatio: 1
        )
    )

    #expect(result.diagnostics?.validity == .lowConfidence)
    #expect(result.confidence < 0.5)
    #expect(abs(result.normalizedPeak) < 0.2)
}

@Test func silenceAndInvalidArrayInputsReturnStructuredErrors() async {
    await #expect(throws: CorrelationAnalysisError.emptyReference) {
        try await CorrelationEngine().correlate(reference: [], observed: [1])
    }
    await #expect(throws: CorrelationAnalysisError.emptyObserved) {
        try await CorrelationEngine().correlate(reference: [1], observed: [])
    }
    await #expect(throws: CorrelationAnalysisError.self) {
        try await CorrelationEngine().correlate(reference: [0, 0], observed: [0, 0])
    }
    await #expect(throws: CorrelationAnalysisError.nonFiniteObserved(index: 1)) {
        try await CorrelationEngine().correlate(reference: [1], observed: [0, .nan])
    }
    await #expect(throws: CorrelationAnalysisError.self) {
        try await CorrelationEngine().correlate(
            reference: [1, -1, 0.5],
            observed: [1, -1, 0.5],
            configuration: CorrelationConfiguration(
                searchRange: SampleLagRange(minimum: 10, maximum: 20)
            )
        )
    }
}

@Test func delayEngineRejectsImplicitFormatChanges() async throws {
    let mono48 = try correlationBuffer([0.5, -0.25, 1], rate: .hz48000, channels: 1)
    let mono44 = try correlationBuffer([0.5, -0.25, 1], rate: .hz44100, channels: 1)
    let stereo48 = try correlationBuffer([0.5, -0.25, 1, 0.5, -0.25, 1], rate: .hz48000, channels: 2)

    await #expect(throws: CorrelationAnalysisError.self) {
        try await DelayAnalysisEngine().analyze(reference: mono48, observed: mono44)
    }
    await #expect(throws: CorrelationAnalysisError.self) {
        try await DelayAnalysisEngine().analyze(reference: mono48, observed: stereo48)
    }
}

@Test func delayUnitsWorkAtStandardMeasurementRates() async throws {
    let reference = deterministicCorrelationNoise(count: 512, seed: 24)
    for rate in [SampleRate.hz44100, .hz48000, .hz96000] {
        let observed = [Float](repeating: 0, count: 100) + reference + [Float](repeating: 0, count: 20)
        let result = try await DelayAnalysisEngine().analyze(
            reference: correlationBuffer(reference, rate: rate, channels: 1),
            observed: correlationBuffer(observed, rate: rate, channels: 1),
            configuration: CorrelationConfiguration(
                method: .fft,
                searchRange: SampleLagRange(minimum: 0, maximum: 110),
                minimumOverlapRatio: 1
            )
        )
        #expect(result.delay.sampleOffset.rawValue == 100)
        #expect(abs(result.delay.fractionalMilliseconds - 100 / rate.hertz * 1_000) < 1e-6)
    }
}

@Test func parabolicInterpolationRecoversFractionalDelay() async throws {
    let integerDelay = 23
    let fractionalDelay = 0.35
    let center = 256.0
    let width = 70.0
    let reference = (0..<512).map { index -> Float in
        fractionalFixtureValue(Double(index) - center, width: width)
    }
    var observed = (0..<600).map { index -> Float in
        let time = Double(index) - Double(integerDelay) - fractionalDelay - center
        return fractionalFixtureValue(time, width: width)
    }
    let noise = deterministicCorrelationNoise(count: observed.count, seed: 444)
    for index in observed.indices { observed[index] += noise[index] * 0.002 }
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .fft,
            searchRange: SampleLagRange(minimum: 10, maximum: 40),
            sequenceOutput: .searchedRange,
            minimumOverlapRatio: 0.9
        )
    )
    let fractionalLag = try #require(result.primaryPeak?.fractionalLag)

    #expect(result.peakOffset.rawValue == 23)
    #expect(abs(fractionalLag - 23.35) < 0.08)
    #expect(result.diagnostics?.interpolationStatus == .applied)
}

@Test func searchBoundaryDisablesInterpolationAndIsDiagnosed() async throws {
    let reference = deterministicCorrelationNoise(count: 256, seed: 66)
    let observed = [Float](repeating: 0, count: 20) + reference
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .direct,
            searchRange: SampleLagRange(minimum: 20, maximum: 20),
            sequenceOutput: .searchedRange,
            minimumOverlapRatio: 1
        )
    )
    #expect(result.primaryPeak?.fractionalLag == nil)
    #expect(result.diagnostics?.interpolationStatus == .peakAtSequenceBoundary)
    #expect(result.diagnostics?.peakAtSearchBoundary == true)
}

@Test func automaticMethodUsesFFTForSeveralSecondsOfAudio() async throws {
    let reference = deterministicCorrelationNoise(count: 144_000, seed: 777)
    let delay = 12_345
    let observed = [Float](repeating: 0, count: delay) + reference + [Float](repeating: 0, count: 20_000)
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await CorrelationEngine().correlate(
        reference: reference,
        observed: observed,
        configuration: CorrelationConfiguration(
            method: .automatic,
            searchRange: SampleLagRange(minimum: 0, maximum: 30_000),
            sequenceOutput: .none,
            minimumOverlapRatio: 1
        )
    )
    let elapsed = start.duration(to: clock.now)

    #expect(result.peakOffset.rawValue == Int64(delay))
    #expect(result.diagnostics?.implementation == .fft)
    #expect(result.diagnostics?.fftLength == 524_288)
    #expect(elapsed < .seconds(10))
    #expect(result.diagnostics?.estimatedWorkingSetBytes ?? 0 > 0)
}

@Test func cancellationAndConcurrentCacheUseAreSafe() async throws {
    let longReference = deterministicCorrelationNoise(count: 20_000, seed: 5)
    let longObserved = deterministicCorrelationNoise(count: 40_000, seed: 6)
    let cancellationTask = Task {
        try await CorrelationEngine().correlate(
            reference: longReference,
            observed: longObserved,
            configuration: CorrelationConfiguration(
                method: .direct,
                searchRange: SampleLagRange(minimum: 0, maximum: 15_000),
                sequenceOutput: .none,
                minimumOverlapRatio: 1
            )
        )
    }
    cancellationTask.cancel()
    await #expect(throws: CorrelationAnalysisError.cancelled) {
        try await cancellationTask.value
    }

    let engine = CorrelationEngine(maximumCachedFFTSetups: 2)
    let reference = deterministicCorrelationNoise(count: 2_048, seed: 12)
    let delays = [13, 29, 47, 83]
    let found = try await withThrowingTaskGroup(of: Int64.self) { group in
        for delay in delays {
            group.addTask {
                let observed = [Float](repeating: 0, count: delay) + reference + [Float](repeating: 0, count: delay)
                let result = try await engine.correlate(
                    reference: reference,
                    observed: observed,
                    configuration: CorrelationConfiguration(
                        method: .fft,
                        searchRange: SampleLagRange(minimum: 0, maximum: 100),
                        sequenceOutput: .none,
                        minimumOverlapRatio: 1
                    )
                )
                return result.peakOffset.rawValue
            }
        }
        var values: [Int64] = []
        for try await value in group { values.append(value) }
        return values.sorted()
    }
    #expect(found == delays.map(Int64.init).sorted())
}

private func deterministicCorrelationNoise(count: Int, seed: UInt64) -> [Float] {
    var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    return (0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        let unit = Double(state & 0x00FF_FFFF) / Double(0x0100_0000)
        return Float(unit * 2 - 1)
    }
}

private func overridingMethod(
    _ value: CorrelationConfiguration,
    with method: CorrelationMethod
) -> CorrelationConfiguration {
    var result = value
    result.method = method
    return result
}

private func correlationBuffer(
    _ samples: [Float],
    rate: SampleRate,
    channels: Int
) throws -> AudioSampleBuffer {
    try AudioSampleBuffer(
        samples: samples,
        format: AudioFormatDescriptor(
            sampleRate: rate,
            channelCount: channels,
            bitDepth: 32,
            isInterleaved: false
        )
    )
}

private func fractionalFixtureValue(_ time: Double, width: Double) -> Float {
    let envelope = exp(-0.5 * pow(time / width, 2))
    return Float(envelope * (sin(0.41 * time) + 0.35 * cos(0.17 * time)))
}
