import AudioLinkCore
import Foundation

public struct MeasurementStatisticsCalculator: Sendable {
    public init() {}

    public func calculate(
        delays: [SampleCount],
        sampleRate: SampleRate,
        clockDrift: PartsPerMillion? = nil
    ) throws -> MeasurementStatistics {
        guard !delays.isEmpty else {
            throw MeasurementError.invalidConfiguration(
                ErrorContext(diagnosticMessage: "At least one delay sample is required.")
            )
        }

        let sorted = delays.sorted()
        let values = delays.map { Double($0.rawValue) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { partial, value in
            partial + (value - mean) * (value - mean)
        } / Double(values.count)
        let jitter = try DurationSeconds(sqrt(variance) / sampleRate.hertz)
        let median: Double
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted.count / 2
            median = (
                Double(sorted[upper - 1].rawValue) + Double(sorted[upper].rawValue)
            ) / 2
        } else {
            median = Double(sorted[sorted.count / 2].rawValue)
        }

        return MeasurementStatistics(
            sampleSize: delays.count,
            meanDelay: SampleCount(rawValue: Int64(mean.rounded())),
            medianDelay: SampleCount(rawValue: Int64(median.rounded())),
            minimumDelay: sorted[0],
            maximumDelay: sorted[sorted.count - 1],
            jitterStandardDeviation: jitter,
            clockDrift: clockDrift
        )
    }
}
