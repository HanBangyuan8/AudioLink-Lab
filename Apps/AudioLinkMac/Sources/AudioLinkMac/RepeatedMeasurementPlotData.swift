import AudioLinkCore
import AudioLinkRealtime
import Foundation

struct RepeatedDelayPlotPoint: Equatable, Identifiable, Sendable {
    let id: UUID
    let runIndex: Int
    let delayMilliseconds: Double?
    let quality: MeasurementQualityLevel?
    let failed: Bool
    let isWarmUp: Bool
    let isOutlier: Bool
}

struct RepeatedHistogramBin: Equatable, Sendable {
    let lowerBound: Double
    let upperBound: Double
    let count: Int
}

struct RepeatedBoxSummary: Equatable, Sendable {
    let minimum: Double
    let q1: Double
    let median: Double
    let q3: Double
    let maximum: Double
}

struct RepeatedMeasurementPlotData: Equatable, Sendable {
    let points: [RepeatedDelayPlotPoint]
    let histogram: [RepeatedHistogramBin]
    let box: RepeatedBoxSummary?

    init(
        outcomes: [RunOutcome],
        statistics: RepeatedMeasurementStatistics?,
        maximumPointCount: Int = 1_000
    ) {
        let outlierIDs = Set(statistics?.outliers.map(\.runID) ?? [])
        let bounded = Array(outcomes.prefix(max(0, maximumPointCount)))
        points = bounded.map {
            RepeatedDelayPlotPoint(
                id: $0.id,
                runIndex: $0.scheduledStepIndex,
                delayMilliseconds: $0.delayMilliseconds,
                quality: $0.qualityLevel,
                failed: !$0.succeeded,
                isWarmUp: $0.isWarmUp,
                isOutlier: outlierIDs.contains($0.id)
            )
        }
        let values = bounded.compactMap(\.delayMilliseconds).sorted()
        histogram = Self.makeHistogram(values)
        if let minimum = values.first, let maximum = values.last,
           let q1 = StatisticalAnalyzer.percentile(sortedValues: values, probability: 0.25),
           let median = StatisticalAnalyzer.percentile(sortedValues: values, probability: 0.5),
           let q3 = StatisticalAnalyzer.percentile(sortedValues: values, probability: 0.75) {
            box = RepeatedBoxSummary(
                minimum: minimum,
                q1: q1,
                median: median,
                q3: q3,
                maximum: maximum
            )
        } else {
            box = nil
        }
    }

    static func makeHistogram(_ sortedValues: [Double]) -> [RepeatedHistogramBin] {
        guard let minimum = sortedValues.first, let maximum = sortedValues.last else { return [] }
        if minimum == maximum {
            return [RepeatedHistogramBin(lowerBound: minimum, upperBound: maximum, count: sortedValues.count)]
        }
        let binCount = min(30, max(1, Int(Double(sortedValues.count).squareRoot().rounded(.up))))
        let width = (maximum - minimum) / Double(binCount)
        var counts = Array(repeating: 0, count: binCount)
        for value in sortedValues {
            let index = min(binCount - 1, max(0, Int((value - minimum) / width)))
            counts[index] += 1
        }
        return counts.indices.map { index in
            RepeatedHistogramBin(
                lowerBound: minimum + Double(index) * width,
                upperBound: minimum + Double(index + 1) * width,
                count: counts[index]
            )
        }
    }
}
