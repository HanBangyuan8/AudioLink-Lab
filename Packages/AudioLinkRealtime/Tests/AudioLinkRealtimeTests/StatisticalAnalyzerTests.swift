import AudioLinkCore
import XCTest
@testable import AudioLinkRealtime

final class StatisticalAnalyzerTests: XCTestCase {
    private let analyzer = StatisticalAnalyzer()

    func testKnownDatasetMeanMedianPercentilesAndJitter() {
        let result = analyze([1, 2, 3, 4, 5])
        XCTAssertEqual(result.populationCount, 5)
        XCTAssertEqual(result.meanMilliseconds ?? .nan, 3, accuracy: 0.000_001)
        XCTAssertEqual(result.medianMilliseconds ?? .nan, 3, accuracy: 0.000_001)
        XCTAssertEqual(result.varianceMillisecondsSquared ?? .nan, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(result.jitterStandardDeviationMilliseconds ?? .nan, sqrt(2.5), accuracy: 0.000_001)
        XCTAssertEqual(result.percentile90Milliseconds ?? .nan, 4.6, accuracy: 0.000_001)
        XCTAssertEqual(result.percentile95Milliseconds ?? .nan, 4.8, accuracy: 0.000_001)
        XCTAssertEqual(result.percentile99Milliseconds ?? .nan, 4.96, accuracy: 0.000_001)
        XCTAssertEqual(result.peakToPeakJitterMilliseconds ?? .nan, 4, accuracy: 0.000_001)
        XCTAssertEqual(result.medianAbsoluteDeviationMilliseconds ?? .nan, 1, accuracy: 0.000_001)
        XCTAssertEqual(result.interquartileRangeMilliseconds ?? .nan, 2, accuracy: 0.000_001)
        XCTAssertEqual(result.reliability, .preliminary)
        XCTAssertNotNil(result.confidenceInterval)
    }

    func testSmallAndEmptySamplesDoNotOverstateReliability() {
        let empty = analyze([])
        XCTAssertNil(empty.meanMilliseconds)
        XCTAssertNil(empty.confidenceInterval)
        XCTAssertEqual(empty.reliability, .insufficient)

        let single = analyze([42])
        XCTAssertEqual(single.varianceMillisecondsSquared, 0)
        XCTAssertEqual(single.jitterStandardDeviationMilliseconds, 0)
        XCTAssertNil(single.confidenceInterval)
        XCTAssertEqual(single.reliability, .insufficient)
    }

    func testAllEqualValuesHaveZeroJitterAndNoOutliers() {
        let result = analyze(Array(repeating: 12.5, count: 20))
        XCTAssertEqual(result.meanMilliseconds, 12.5)
        XCTAssertEqual(result.jitterStandardDeviationMilliseconds, 0)
        XCTAssertEqual(result.peakToPeakJitterMilliseconds, 0)
        XCTAssertTrue(result.outliers.isEmpty)
        XCTAssertEqual(result.reliability, .moderate)
    }

    func testMADMarksExtremeValueAndIncludeExcludeChangesPopulation() {
        let samples = [10, 10.1, 9.9, 10.2, 10.0, 100]
        let including = analyze(samples, include: true, method: .medianAbsoluteDeviation, threshold: 3.5)
        let excluding = analyze(samples, include: false, method: .medianAbsoluteDeviation, threshold: 3.5)
        XCTAssertEqual(including.outliers.count, 1)
        XCTAssertEqual(including.populationCount, 6)
        XCTAssertEqual(excluding.populationCount, 5)
        XCTAssertGreaterThan(including.meanMilliseconds ?? 0, excluding.meanMilliseconds ?? 0)
        XCTAssertTrue(including.outliers[0].score.isFinite)
    }

    func testIQRMarksMultipleExtremeValues() {
        let result = analyze(
            [10, 10, 10, 10, 10, 10, 10, 10, 100, 120],
            include: false,
            method: .interquartileRange,
            threshold: 1.5
        )
        XCTAssertEqual(result.outliers.count, 2)
        XCTAssertEqual(result.populationCount, 8)
        XCTAssertEqual(result.meanMilliseconds, 10)
    }

    func testFailuresDoNotEnterDelayPopulation() {
        let result = analyzer.analyze(
            samples: samples([10, 12]),
            outcomeCount: 4,
            failureCount: 2,
            includeMarkedOutliers: true,
            method: .medianAbsoluteDeviation,
            threshold: 3.5
        )
        XCTAssertEqual(result.outcomeCount, 4)
        XCTAssertEqual(result.successCount, 2)
        XCTAssertEqual(result.failureCount, 2)
        XCTAssertEqual(result.meanMilliseconds, 11)
    }

    func testPercentileBoundaryRulesAreTypeSeven() {
        XCTAssertNil(StatisticalAnalyzer.percentile(sortedValues: [], probability: 0.5))
        XCTAssertEqual(StatisticalAnalyzer.percentile(sortedValues: [7], probability: 0.99), 7)
        XCTAssertEqual(StatisticalAnalyzer.percentile(sortedValues: [1, 2, 3, 4], probability: 0), 1)
        XCTAssertEqual(StatisticalAnalyzer.percentile(sortedValues: [1, 2, 3, 4], probability: 1), 4)
        XCTAssertEqual(StatisticalAnalyzer.percentile(sortedValues: [1, 2, 3, 4], probability: 0.5), 2.5)
    }

    func testQualityDistributionTracksSelectedPopulation() {
        let input = [
            StatisticalRunSample(runID: UUID(), runIndex: 1, delayMilliseconds: 10, qualityLevel: .excellent),
            StatisticalRunSample(runID: UUID(), runIndex: 2, delayMilliseconds: 10.1, qualityLevel: .good),
            StatisticalRunSample(runID: UUID(), runIndex: 3, delayMilliseconds: 9.9, qualityLevel: .questionable),
            StatisticalRunSample(runID: UUID(), runIndex: 4, delayMilliseconds: 100, qualityLevel: .poor)
        ]
        let result = analyzer.analyze(
            samples: input,
            includeMarkedOutliers: false,
            method: .medianAbsoluteDeviation,
            threshold: 3.5
        )
        XCTAssertEqual(result.qualityDistribution.total, result.populationCount)
        XCTAssertEqual(result.qualityDistribution.poor, 0)
    }

    func testCalculationIsDeterministicForStableRunIdentity() {
        let input = samples([10, 10.1, 9.9, 10.2, 100])
        let first = analyzer.analyze(
            samples: input,
            includeMarkedOutliers: false,
            method: .medianAbsoluteDeviation,
            threshold: 3.5
        )
        let second = analyzer.analyze(
            samples: input,
            includeMarkedOutliers: false,
            method: .medianAbsoluteDeviation,
            threshold: 3.5
        )
        XCTAssertEqual(first, second)
    }

    private func analyze(
        _ values: [Double],
        include: Bool = true,
        method: OutlierDetectionMethod = .medianAbsoluteDeviation,
        threshold: Double = 3.5
    ) -> RepeatedMeasurementStatistics {
        analyzer.analyze(
            samples: samples(values),
            includeMarkedOutliers: include,
            method: method,
            threshold: threshold
        )
    }

    private func samples(_ values: [Double]) -> [StatisticalRunSample] {
        values.enumerated().map {
            StatisticalRunSample(
                runID: UUID(),
                runIndex: $0.offset + 1,
                delayMilliseconds: $0.element,
                qualityLevel: .good
            )
        }
    }
}
