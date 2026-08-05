import AudioLinkCore
import Foundation

public struct StatisticalRunSample: Codable, Equatable, Sendable {
    public let runID: UUID
    public let runIndex: Int
    public let delayMilliseconds: Double
    public let qualityLevel: MeasurementQualityLevel

    public init(
        runID: UUID,
        runIndex: Int,
        delayMilliseconds: Double,
        qualityLevel: MeasurementQualityLevel
    ) {
        self.runID = runID
        self.runIndex = runIndex
        self.delayMilliseconds = delayMilliseconds
        self.qualityLevel = qualityLevel
    }
}

public struct OutlierDetector: Sendable {
    public init() {}

    public func detect(
        samples: [StatisticalRunSample],
        method: OutlierDetectionMethod,
        threshold: Double
    ) -> [MeasurementOutlier] {
        guard samples.count >= 4, threshold.isFinite, threshold > 0 else { return [] }
        switch method {
        case .medianAbsoluteDeviation:
            return madOutliers(samples: samples, threshold: threshold)
        case .interquartileRange:
            return iqrOutliers(samples: samples, threshold: threshold)
        }
    }

    private func madOutliers(
        samples: [StatisticalRunSample],
        threshold: Double
    ) -> [MeasurementOutlier] {
        let values = samples.map(\.delayMilliseconds).sorted()
        let median = StatisticalAnalyzer.percentile(sortedValues: values, probability: 0.5) ?? 0
        let deviations = values.map { abs($0 - median) }.sorted()
        let mad = StatisticalAnalyzer.percentile(sortedValues: deviations, probability: 0.5) ?? 0
        let scaledMAD = mad * 1.4826
        return samples.compactMap { sample in
            let deviation = abs(sample.delayMilliseconds - median)
            let score: Double
            if scaledMAD > 0 {
                score = deviation / scaledMAD
            } else if deviation > 0 {
                score = Double.greatestFiniteMagnitude
            } else {
                score = 0
            }
            guard score > threshold else { return nil }
            return MeasurementOutlier(
                id: sample.runID,
                runID: sample.runID,
                runIndex: sample.runIndex,
                delayMilliseconds: sample.delayMilliseconds,
                method: .medianAbsoluteDeviation,
                threshold: threshold,
                score: score,
                explanation: "Absolute deviation from the median exceeded \(threshold) scaled MAD."
            )
        }
    }

    private func iqrOutliers(
        samples: [StatisticalRunSample],
        threshold: Double
    ) -> [MeasurementOutlier] {
        let values = samples.map(\.delayMilliseconds).sorted()
        let q1 = StatisticalAnalyzer.percentile(sortedValues: values, probability: 0.25) ?? 0
        let q3 = StatisticalAnalyzer.percentile(sortedValues: values, probability: 0.75) ?? 0
        let iqr = q3 - q1
        let lower = q1 - threshold * iqr
        let upper = q3 + threshold * iqr
        return samples.compactMap { sample in
            guard sample.delayMilliseconds < lower || sample.delayMilliseconds > upper else { return nil }
            let distance = sample.delayMilliseconds < lower
                ? lower - sample.delayMilliseconds
                : sample.delayMilliseconds - upper
            let score = iqr > 0 ? distance / iqr : Double.greatestFiniteMagnitude
            return MeasurementOutlier(
                id: sample.runID,
                runID: sample.runID,
                runIndex: sample.runIndex,
                delayMilliseconds: sample.delayMilliseconds,
                method: .interquartileRange,
                threshold: threshold,
                score: score,
                explanation: "Delay was outside the \(threshold) × IQR fences [\(lower), \(upper)] ms."
            )
        }
    }
}

public struct StatisticalAnalyzer: Sendable {
    private let outlierDetector: OutlierDetector

    public init(outlierDetector: OutlierDetector = .init()) {
        self.outlierDetector = outlierDetector
    }

    public func analyze(
        outcomes: [RunOutcome],
        includeMarkedOutliers: Bool,
        method: OutlierDetectionMethod,
        threshold: Double
    ) -> RepeatedMeasurementStatistics {
        let eligible = outcomes.filter { !$0.isDiscardedWarmUp }
        let samples = eligible.compactMap { outcome -> StatisticalRunSample? in
            guard let delay = outcome.delayMilliseconds,
                  let quality = outcome.qualityLevel else { return nil }
            return StatisticalRunSample(
                runID: outcome.id,
                runIndex: outcome.measuredRunIndex ?? outcome.scheduledStepIndex,
                delayMilliseconds: delay,
                qualityLevel: quality
            )
        }
        return analyze(
            samples: samples,
            outcomeCount: eligible.count,
            failureCount: eligible.filter { !$0.succeeded }.count,
            includeMarkedOutliers: includeMarkedOutliers,
            method: method,
            threshold: threshold
        )
    }

    public func analyze(
        samples: [StatisticalRunSample],
        outcomeCount: Int? = nil,
        failureCount: Int = 0,
        includeMarkedOutliers: Bool,
        method: OutlierDetectionMethod,
        threshold: Double
    ) -> RepeatedMeasurementStatistics {
        let outliers = outlierDetector.detect(samples: samples, method: method, threshold: threshold)
        let outlierIDs = Set(outliers.map(\.runID))
        let population = includeMarkedOutliers
            ? samples
            : samples.filter { !outlierIDs.contains($0.runID) }
        let sorted = population.map(\.delayMilliseconds).sorted()
        let count = sorted.count
        let mean = count > 0 ? sorted.reduce(0, +) / Double(count) : nil
        let variance: Double?
        if count >= 2, let mean {
            variance = sorted.reduce(0) { partial, value in
                let delta = value - mean
                return partial + delta * delta
            } / Double(count - 1)
        } else if count == 1 {
            variance = 0
        } else {
            variance = nil
        }
        let median = Self.percentile(sortedValues: sorted, probability: 0.5)
        let deviations = median.map { center in sorted.map { abs($0 - center) }.sorted() } ?? []
        let q1 = Self.percentile(sortedValues: sorted, probability: 0.25)
        let q3 = Self.percentile(sortedValues: sorted, probability: 0.75)
        return RepeatedMeasurementStatistics(
            outcomeCount: outcomeCount ?? (samples.count + failureCount),
            successCount: samples.count,
            failureCount: failureCount,
            populationCount: count,
            includesMarkedOutliers: includeMarkedOutliers,
            minimumMilliseconds: sorted.first,
            maximumMilliseconds: sorted.last,
            meanMilliseconds: mean,
            medianMilliseconds: median,
            varianceMillisecondsSquared: variance,
            jitterStandardDeviationMilliseconds: variance.map(sqrt),
            percentile50Milliseconds: median,
            percentile90Milliseconds: Self.percentile(sortedValues: sorted, probability: 0.90),
            percentile95Milliseconds: Self.percentile(sortedValues: sorted, probability: 0.95),
            percentile99Milliseconds: Self.percentile(sortedValues: sorted, probability: 0.99),
            peakToPeakJitterMilliseconds: sorted.first.flatMap { minimum in
                sorted.last.map { $0 - minimum }
            },
            medianAbsoluteDeviationMilliseconds: Self.percentile(
                sortedValues: deviations,
                probability: 0.5
            ),
            interquartileRangeMilliseconds: q1.flatMap { lower in q3.map { $0 - lower } },
            confidenceInterval: confidenceInterval(mean: mean, variance: variance, count: count),
            qualityDistribution: qualityDistribution(population),
            outliers: outliers,
            outlierMethod: method,
            outlierThreshold: threshold,
            reliability: reliability(count: count)
        )
    }

    /// Hyndman–Fan type 7 linear interpolation, used by NumPy and R defaults.
    public static func percentile(
        sortedValues: [Double],
        probability: Double
    ) -> Double? {
        guard !sortedValues.isEmpty, probability.isFinite else { return nil }
        if sortedValues.count == 1 { return sortedValues[0] }
        let bounded = min(1, max(0, probability))
        let position = bounded * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        if lowerIndex == upperIndex { return sortedValues[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sortedValues[lowerIndex]
            + fraction * (sortedValues[upperIndex] - sortedValues[lowerIndex])
    }

    private func confidenceInterval(
        mean: Double?,
        variance: Double?,
        count: Int
    ) -> StatisticalConfidenceInterval? {
        guard count >= 2, let mean, let variance else { return nil }
        let critical = studentTCritical95(degreesOfFreedom: count - 1)
        let margin = critical * sqrt(variance / Double(count))
        return StatisticalConfidenceInterval(
            confidenceLevel: 0.95,
            lowerBoundMilliseconds: mean - margin,
            upperBoundMilliseconds: mean + margin,
            method: "Two-sided Student t interval for the arithmetic mean"
        )
    }

    private func studentTCritical95(degreesOfFreedom: Int) -> Double {
        let table = [
            12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306,
            2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131, 2.120,
            2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064,
            2.060, 2.056, 2.052, 2.048, 2.045, 2.042
        ]
        if degreesOfFreedom <= 0 { return .infinity }
        if degreesOfFreedom <= table.count { return table[degreesOfFreedom - 1] }
        if degreesOfFreedom < 60 { return 2.000 }
        if degreesOfFreedom < 120 { return 1.980 }
        return 1.960
    }

    private func qualityDistribution(_ samples: [StatisticalRunSample]) -> QualityLevelDistribution {
        QualityLevelDistribution(
            excellent: samples.filter { $0.qualityLevel == .excellent }.count,
            good: samples.filter { $0.qualityLevel == .good }.count,
            questionable: samples.filter { $0.qualityLevel == .questionable }.count,
            poor: samples.filter { $0.qualityLevel == .poor }.count,
            invalid: samples.filter { $0.qualityLevel == .invalid }.count
        )
    }

    private func reliability(count: Int) -> StatisticalReliability {
        switch count {
        case 0...4: .insufficient
        case 5...19: .preliminary
        case 20...49: .moderate
        default: .strong
        }
    }
}
