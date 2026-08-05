import AudioLinkCore
import AudioLinkRealtime
import Foundation
import Testing
@testable import AudioLinkMac

@Test
func repeatedPlotPreparationIsBoundedAndKeepsFailedMarkers() {
    let failure = RealtimeMeasurementFailure(
        code: .recordingFailed,
        userMessage: "fixture",
        recoverySuggestion: "retry"
    )
    var outcomes: [RunOutcome] = []
    outcomes.reserveCapacity(2_000)
    for index in 0..<2_000 {
        let startedAt = Date(timeIntervalSince1970: Double(index))
        outcomes.append(RunOutcome(
            scheduledStepIndex: index + 1,
            measuredRunIndex: index + 1,
            isWarmUp: false,
            isDiscardedWarmUp: false,
            seed: UInt64(index),
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(0.1),
            failure: RepeatedMeasurementRunFailure(failure: failure)
        ))
    }
    let data = RepeatedMeasurementPlotData(
        outcomes: outcomes,
        statistics: nil,
        maximumPointCount: 1_000
    )
    #expect(data.points.count == 1_000)
    #expect(data.points.allSatisfy { $0.failed })
    #expect(data.points.last?.runIndex == 1_000)
    #expect(data.histogram.isEmpty)
    #expect(data.box == nil)
}

@Test
func histogramCoversEveryValueIncludingMaximumBoundary() {
    let values = [1.0, 1.0, 2.0, 3.0, 4.0, 5.0]
    let bins = RepeatedMeasurementPlotData.makeHistogram(values.sorted())
    #expect(!bins.isEmpty)
    #expect(bins.map(\.count).reduce(0, +) == values.count)
    #expect(bins.last?.upperBound == 5)
}

@Test
func constantHistogramUsesOneNonEmptyBin() {
    let bins = RepeatedMeasurementPlotData.makeHistogram(Array(repeating: 12.5, count: 100))
    #expect(bins == [RepeatedHistogramBin(lowerBound: 12.5, upperBound: 12.5, count: 100)])
}
