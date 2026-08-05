import AudioLinkCore
import Testing
@testable import AudioLinkDSP

@Test func clockDriftEstimatorRecoversPositiveAndNegativePPM() throws {
    for ppm in [10.0, 50.0, 100.0, -50.0, 0.0] {
        let observations = (0..<12).map { index in
            let expected = Double(index) * 48_000 * 2
            let observed = expected * (1 + ppm / 1_000_000) + 137
            return DriftObservation(eventIndex: index, expectedSamplePosition: expected, observedSamplePosition: observed)
        }
        let estimate = try ClockDriftEstimator().estimate(observations: observations)
        #expect(abs(estimate.driftPPM - ppm) < 0.001)
        #expect(abs(estimate.constantOffsetSamples - 137) < 0.001)
        #expect(estimate.confidence > 0.99)
    }
}

@Test func clockDriftEstimatorMarksOutliersAndNonlinearity() throws {
    var observations = (0..<10).map { index in
        let expected = Double(index) * 48_000
        return DriftObservation(eventIndex: index, expectedSamplePosition: expected, observedSamplePosition: expected + 50)
    }
    observations[5] = DriftObservation(eventIndex: 5, expectedSamplePosition: 240_000, observedSamplePosition: 241_000)
    let estimate = try ClockDriftEstimator().estimate(observations: observations)
    #expect(estimate.outlierEventIndices == [5])
    #expect(abs(estimate.constantOffsetSamples - 50) < 0.001)
}

@Test func clockDriftEstimatorRejectsMissingOrInvalidData() throws {
    #expect(throws: ClockDriftError.insufficientObservations(required: 3, actual: 2)) {
        _ = try ClockDriftEstimator().estimate(observations: [
            DriftObservation(eventIndex: 0, expectedSamplePosition: 0, observedSamplePosition: 1),
            DriftObservation(eventIndex: 1, expectedSamplePosition: 1, observedSamplePosition: 2)
        ])
    }
}
