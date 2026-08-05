import Foundation

public enum OutlierDetectionMethod: String, Codable, CaseIterable, Sendable {
    case medianAbsoluteDeviation
    case interquartileRange
}

public enum StatisticalReliability: String, Codable, CaseIterable, Sendable {
    case insufficient
    case preliminary
    case moderate
    case strong
}

public struct StatisticalConfidenceInterval: Codable, Equatable, Sendable {
    public let confidenceLevel: Double
    public let lowerBoundMilliseconds: Double
    public let upperBoundMilliseconds: Double
    public let method: String

    public init(
        confidenceLevel: Double,
        lowerBoundMilliseconds: Double,
        upperBoundMilliseconds: Double,
        method: String
    ) {
        self.confidenceLevel = confidenceLevel
        self.lowerBoundMilliseconds = lowerBoundMilliseconds
        self.upperBoundMilliseconds = upperBoundMilliseconds
        self.method = method
    }
}

public struct QualityLevelDistribution: Codable, Equatable, Sendable {
    public let excellent: Int
    public let good: Int
    public let questionable: Int
    public let poor: Int
    public let invalid: Int

    public init(
        excellent: Int = 0,
        good: Int = 0,
        questionable: Int = 0,
        poor: Int = 0,
        invalid: Int = 0
    ) {
        self.excellent = excellent
        self.good = good
        self.questionable = questionable
        self.poor = poor
        self.invalid = invalid
    }

    public var total: Int { excellent + good + questionable + poor + invalid }

    public func count(for level: MeasurementQualityLevel) -> Int {
        switch level {
        case .excellent: excellent
        case .good: good
        case .questionable: questionable
        case .poor: poor
        case .invalid: invalid
        }
    }
}

public struct MeasurementOutlier: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let runIndex: Int
    public let delayMilliseconds: Double
    public let method: OutlierDetectionMethod
    public let threshold: Double
    public let score: Double
    public let explanation: String

    public init(
        id: UUID = UUID(),
        runID: UUID,
        runIndex: Int,
        delayMilliseconds: Double,
        method: OutlierDetectionMethod,
        threshold: Double,
        score: Double,
        explanation: String
    ) {
        self.id = id
        self.runID = runID
        self.runIndex = runIndex
        self.delayMilliseconds = delayMilliseconds
        self.method = method
        self.threshold = threshold
        self.score = score
        self.explanation = explanation
    }
}

/// Aggregate delay values are expressed in milliseconds. Variance is therefore
/// in milliseconds squared. `jitterStandardDeviationMilliseconds` defines
/// jitter as the sample standard deviation of successful delay observations in
/// the selected population (including or excluding marked outliers).
public struct RepeatedMeasurementStatistics: Codable, Equatable, Sendable {
    public let outcomeCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let populationCount: Int
    public let includesMarkedOutliers: Bool
    public let minimumMilliseconds: Double?
    public let maximumMilliseconds: Double?
    public let meanMilliseconds: Double?
    public let medianMilliseconds: Double?
    public let varianceMillisecondsSquared: Double?
    public let jitterStandardDeviationMilliseconds: Double?
    public let percentile50Milliseconds: Double?
    public let percentile90Milliseconds: Double?
    public let percentile95Milliseconds: Double?
    public let percentile99Milliseconds: Double?
    public let peakToPeakJitterMilliseconds: Double?
    public let medianAbsoluteDeviationMilliseconds: Double?
    public let interquartileRangeMilliseconds: Double?
    public let confidenceInterval: StatisticalConfidenceInterval?
    public let qualityDistribution: QualityLevelDistribution
    public let outliers: [MeasurementOutlier]
    public let outlierMethod: OutlierDetectionMethod
    public let outlierThreshold: Double
    public let reliability: StatisticalReliability

    public init(
        outcomeCount: Int,
        successCount: Int,
        failureCount: Int,
        populationCount: Int,
        includesMarkedOutliers: Bool,
        minimumMilliseconds: Double?,
        maximumMilliseconds: Double?,
        meanMilliseconds: Double?,
        medianMilliseconds: Double?,
        varianceMillisecondsSquared: Double?,
        jitterStandardDeviationMilliseconds: Double?,
        percentile50Milliseconds: Double?,
        percentile90Milliseconds: Double?,
        percentile95Milliseconds: Double?,
        percentile99Milliseconds: Double?,
        peakToPeakJitterMilliseconds: Double?,
        medianAbsoluteDeviationMilliseconds: Double?,
        interquartileRangeMilliseconds: Double?,
        confidenceInterval: StatisticalConfidenceInterval?,
        qualityDistribution: QualityLevelDistribution,
        outliers: [MeasurementOutlier],
        outlierMethod: OutlierDetectionMethod,
        outlierThreshold: Double,
        reliability: StatisticalReliability
    ) {
        self.outcomeCount = outcomeCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.populationCount = populationCount
        self.includesMarkedOutliers = includesMarkedOutliers
        self.minimumMilliseconds = minimumMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.meanMilliseconds = meanMilliseconds
        self.medianMilliseconds = medianMilliseconds
        self.varianceMillisecondsSquared = varianceMillisecondsSquared
        self.jitterStandardDeviationMilliseconds = jitterStandardDeviationMilliseconds
        self.percentile50Milliseconds = percentile50Milliseconds
        self.percentile90Milliseconds = percentile90Milliseconds
        self.percentile95Milliseconds = percentile95Milliseconds
        self.percentile99Milliseconds = percentile99Milliseconds
        self.peakToPeakJitterMilliseconds = peakToPeakJitterMilliseconds
        self.medianAbsoluteDeviationMilliseconds = medianAbsoluteDeviationMilliseconds
        self.interquartileRangeMilliseconds = interquartileRangeMilliseconds
        self.confidenceInterval = confidenceInterval
        self.qualityDistribution = qualityDistribution
        self.outliers = outliers
        self.outlierMethod = outlierMethod
        self.outlierThreshold = outlierThreshold
        self.reliability = reliability
    }
}
