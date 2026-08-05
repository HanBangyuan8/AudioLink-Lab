import AudioLinkCore
import Testing
@testable import AudioLinkDSP

@Test func sineGeneratorProducesExpectedFrameCount() throws {
    let buffer = try SineSignalGenerator().generate(
        frequencyHertz: 1_000,
        duration: DurationSeconds(0.01),
        sampleRate: .hz48000
    )

    #expect(buffer.samples.count == 480)
    #expect(buffer.samples.allSatisfy { abs($0) <= 0.5 })
}

@Test func correlationFindsKnownPositiveDelay() throws {
    let reference: [Float] = [0.1, -0.25, 0.8, -0.4, 0.2]
    let observed: [Float] = [0, 0, 0] + reference + [0, 0]
    let result = try CrossCorrelationAnalyzer().analyze(reference: reference, observed: observed)

    #expect(result.peakOffset == SampleCount(rawValue: 3))
    #expect(result.normalizedPeak > 0.999)
}

@Test func statisticsUseSamplesAsCanonicalDelay() throws {
    let statistics = try MeasurementStatisticsCalculator().calculate(
        delays: [480, 481, 479, 480].map { SampleCount(rawValue: $0) },
        sampleRate: .hz48000
    )

    #expect(statistics.meanDelay == SampleCount(rawValue: 480))
    #expect(statistics.medianDelay == SampleCount(rawValue: 480))
    #expect(statistics.minimumDelay == SampleCount(rawValue: 479))
    #expect(statistics.jitterStandardDeviation.milliseconds < 0.02)
}

